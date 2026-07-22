#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "🎬 Clip Cutter - Auto Installer"
echo "================================"

echo "[1/6] Update & install paket (python, ffmpeg, git)..."
pkg update -y && pkg upgrade -y
pkg install -y python ffmpeg git

echo "[2/6] Install Flask..."
pip install --upgrade pip
pip install flask

echo "[3/6] Setup akses storage (izinkan lewat pop-up yang muncul)..."
termux-setup-storage
sleep 2

echo "[4/6] Menulis app.py ke ~/clipcutter ..."
mkdir -p ~/clipcutter
cat > ~/clipcutter/app.py << 'APPEOF'
#!/usr/bin/env python3
"""
Clip Cutter Web - untuk dijalankan di Termux
Potong video berdasarkan daftar timestamp yang di-paste,
dengan audio & video presisi (sinkron, tidak telat),
progress % real-time per klip, dan preview video di web.
"""

import os
import re
import time
import uuid
import threading
import shutil
import subprocess
from flask import Flask, request, send_from_directory, url_for, redirect, jsonify

app = Flask(__name__)

# Output disimpan di dalam folder script ini sendiri -> ~/clipcutter/output/
# Lokasi ini aman ditulis oleh Termux (tidak kena batasan izin Android).
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
os.makedirs(OUTPUT_DIR, exist_ok=True)

LINE_PATTERN = re.compile(
    r"^\s*(\d{2}:\d{2}:\d{2})\s*-\s*(\d{2}:\d{2}:\d{2})\s+(.+?)\s*$"
)

# Menyimpan status semua job yang sedang/sudah diproses, key = session_id
JOBS = {}
JOBS_LOCK = threading.Lock()


def sanitize_filename(name: str) -> str:
    name = re.sub(r"[^\w\s\-()]", "", name, flags=re.UNICODE)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:120] if name else "clip"


def parse_lines(raw_text: str):
    jobs = []
    errors = []
    for i, line in enumerate(raw_text.splitlines(), start=1):
        if not line.strip():
            continue
        m = LINE_PATTERN.match(line)
        if not m:
            errors.append(f"Baris {i} tidak dikenali formatnya: {line}")
            continue
        start, end, title = m.groups()
        jobs.append((start, end, title))
    return jobs, errors


def to_seconds(hms: str) -> int:
    h, m, s = hms.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def cut_clip_with_progress(input_path, start, end, out_path, on_progress):
    """
    Potong 1 klip dengan stream-copy (tanpa re-encode, cepat).
    -ss diletakkan SEBELUM -i supaya fast+accurate seek.
    """
    duration = max(1, to_seconds(end) - to_seconds(start))

    cmd = [
        "ffmpeg", "-y",
        "-ss", start,
        "-i", input_path,
        "-t", str(duration),
        "-map", "0:v:0",
        "-map", "0:a:0?",
        "-c", "copy",
        "-avoid_negative_ts", "make_zero",
        "-movflags", "+faststart",
        "-progress", "pipe:1",
        "-nostats",
        out_path,
    ]

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        universal_newlines=True, bufsize=1,
    )

    stderr_lines = []

    def read_stderr():
        for line in proc.stderr:
            stderr_lines.append(line)

    t = threading.Thread(target=read_stderr, daemon=True)
    t.start()

    for line in proc.stdout:
        line = line.strip()
        if line.startswith("out_time_ms="):
            try:
                ms = int(line.split("=")[1])
                pct = int((ms / 1_000_000) / duration * 100)
                on_progress(max(0, min(99, pct)))
            except (ValueError, ZeroDivisionError):
                pass
        elif line == "progress=end":
            on_progress(100)

    proc.wait()
    t.join(timeout=2)

    success = proc.returncode == 0
    return success, "".join(stderr_lines)[-2000:]


MAX_AGE_SECONDS = 24 * 60 * 60  # 24 jam
CLEANUP_INTERVAL_SECONDS = 30 * 60  # cek tiap 30 menit


def cleanup_old_outputs():
    while True:
        try:
            now = time.time()
            if os.path.isdir(OUTPUT_DIR):
                for name in os.listdir(OUTPUT_DIR):
                    folder = os.path.join(OUTPUT_DIR, name)
                    if not os.path.isdir(folder):
                        continue
                    age = now - os.path.getmtime(folder)
                    if age > MAX_AGE_SECONDS:
                        shutil.rmtree(folder, ignore_errors=True)
                        with JOBS_LOCK:
                            JOBS.pop(name, None)
                        print(f"[cleanup] Menghapus folder kadaluarsa: {folder}")
        except Exception as e:
            print(f"[cleanup] Error: {e}")
        time.sleep(CLEANUP_INTERVAL_SECONDS)


def run_job(session_id, video_path):
    state = JOBS[session_id]
    session_dir = os.path.join(OUTPUT_DIR, session_id)

    try:
        os.makedirs(session_dir, exist_ok=True)
    except OSError as e:
        state["fatal_error"] = f"Tidak bisa membuat folder output: {e}"
        state["finished"] = True
        return

    for clip in state["clips"]:
        clip["status"] = "processing"

        def cb(pct, clip=clip):
            clip["progress"] = pct

        out_path = os.path.join(session_dir, clip["filename"])
        success, log = cut_clip_with_progress(
            video_path, clip["start"], clip["end"], out_path, cb
        )
        if success:
            clip["status"] = "done"
            clip["progress"] = 100
        else:
            clip["status"] = "error"
            clip["progress"] = 100
            clip["log"] = log

    state["finished"] = True


INDEX_TEMPLATE = """<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Clip Cutter - Termux</title>
<style>
  :root {{
    --bg:#0f1115; --panel:#171a21; --accent:#4f8cff;
    --text:#e7e9ee; --muted:#9aa1ac; --ok:#38c172; --err:#ff5c5c;
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; font-family:-apple-system,Segoe UI,Roboto,sans-serif;
    background:var(--bg); color:var(--text); padding:16px; }}
  h1 {{ font-size:1.3rem; margin-bottom:4px; }}
  p.sub {{ color:var(--muted); margin-top:0; font-size:0.85rem; }}
  .panel {{ background:var(--panel); border-radius:12px; padding:16px;
    margin-bottom:16px; border:1px solid #262a33; }}
  label {{ display:block; margin-bottom:6px; font-weight:600; font-size:0.9rem; }}
  input[type=text], textarea {{ width:100%; background:#0f1115; color:var(--text);
    border:1px solid #2c3140; border-radius:8px; padding:10px;
    font-size:0.9rem; font-family:monospace; }}
  textarea {{ min-height:220px; resize:vertical; }}
  button {{ background:var(--accent); color:white; border:none;
    padding:12px 20px; border-radius:8px; font-size:1rem;
    font-weight:600; cursor:pointer; width:100%; margin-top:12px; }}
  .example {{ color:var(--muted); font-size:0.8rem; white-space:pre-wrap; margin-top:6px; }}
  .out-info {{ color:var(--muted); font-size:0.8rem; margin-top:-6px; margin-bottom:16px; }}
</style>
</head>
<body>
  <h1>🎬 Clip Cutter</h1>
  <p class="sub">Potong video jadi beberapa klip presisi (audio & video tetap sinkron)</p>
  <p class="out-info">📁 Hasil disimpan ke: <code>{output_dir}</code></p>

  <form method="POST" action="/process">
    <div class="panel">
      <label>Lokasi File Video</label>
      <input type="text" name="video_path" placeholder="/storage/emulated/0/snaptube/download/SnapTube Video/nama_video.mp4" required>
    </div>

    <div class="panel">
      <label>Paste Daftar Potongan</label>
      <textarea name="raw_text" placeholder="00:03:52-00:04:36 Judul Klip 1
00:33:48-00:35:10 Judul Klip 2" required></textarea>
      <div class="example">Format tiap baris:
HH:MM:SS-HH:MM:SS Judul Klip</div>
    </div>

    <button type="submit">Proses Potong Video</button>
  </form>
</body>
</html>
"""

STATUS_TEMPLATE = """<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Memproses... - Clip Cutter</title>
<style>
  :root {{
    --bg:#0f1115; --panel:#171a21; --accent:#4f8cff;
    --text:#e7e9ee; --muted:#9aa1ac; --ok:#38c172; --err:#ff5c5c;
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; font-family:-apple-system,Segoe UI,Roboto,sans-serif;
    background:var(--bg); color:var(--text); padding:16px; }}
  h1 {{ font-size:1.3rem; margin-bottom:4px; }}
  p.sub {{ color:var(--muted); margin-top:0; font-size:0.85rem; }}
  a.back {{ color:var(--accent); text-decoration:none; font-size:0.85rem; }}
  .clip {{ background:var(--panel); border-radius:12px; padding:14px;
    margin-bottom:12px; border:1px solid #262a33; }}
  .clip-title {{ font-weight:600; margin-bottom:6px; font-size:0.92rem; }}
  .clip-time {{ color:var(--muted); font-size:0.78rem; margin-bottom:8px; }}
  .bar-bg {{ background:#0f1115; border-radius:6px; height:16px; overflow:hidden; border:1px solid #2c3140; }}
  .bar-fill {{ height:100%; background:var(--accent); width:0%; transition:width .3s; }}
  .bar-fill.done {{ background:var(--ok); }}
  .bar-fill.error {{ background:var(--err); }}
  .pct {{ font-size:0.78rem; color:var(--muted); margin-top:4px; }}
  .dl {{ display:inline-block; margin-top:10px; margin-right:10px; color:var(--ok); text-decoration:none; font-weight:600; font-size:0.85rem; }}
  video {{ width:100%; border-radius:8px; margin-top:10px; background:#000; }}
  .errlog {{ white-space:pre-wrap; font-size:0.72rem; color:var(--err); margin-top:6px; background:#0f1115; padding:8px; border-radius:6px; }}
  .fatal {{ background:#2a1414; border:1px solid var(--err); border-radius:12px; padding:14px; white-space:pre-wrap; font-size:0.85rem; }}
</style>
</head>
<body>
  <a class="back" href="/">← Potong video lain</a>
  <h1>Sedang Memproses...</h1>
  <p class="sub" id="overall-status">Menyiapkan...</p>

  <div id="clips"></div>

  <script>
    const sessionId = "{session_id}";
    async function poll() {{
      const res = await fetch("/api/status/" + sessionId);
      const data = await res.json();

      if (data.fatal_error) {{
        document.getElementById("clips").innerHTML =
          '<div class="fatal">' + data.fatal_error + '</div>';
        document.getElementById("overall-status").innerText = "Gagal";
        return;
      }}

      let doneCount = 0;
      let html = "";
      data.clips.forEach(c => {{
        if (c.status === "done" || c.status === "error") doneCount++;
        let barClass = c.status === "done" ? "done" : (c.status === "error" ? "error" : "");
        let statusLabel = {{
          pending: "Menunggu...",
          processing: "Memotong... " + c.progress + "%",
          done: "✅ Berhasil",
          error: "❌ Gagal"
        }}[c.status];

        html += '<div class="clip">' +
          '<div class="clip-title">' + c.filename + '</div>' +
          '<div class="clip-time">' + c.start + ' - ' + c.end + '</div>' +
          '<div class="bar-bg"><div class="bar-fill ' + barClass + '" style="width:' + c.progress + '%"></div></div>' +
          '<div class="pct">' + statusLabel + '</div>' +
          (c.status === "done" ?
            '<video controls preload="metadata" src="' + c.download_url + '"></video>' +
            '<div><a class="dl" href="' + c.download_url + '" download>⬇ Download</a></div>'
            : '') +
          (c.status === "error" ? '<div class="errlog">' + c.log + '</div>' : '') +
          '</div>';
      }});
      document.getElementById("clips").innerHTML = html;
      document.getElementById("overall-status").innerText =
        doneCount + " / " + data.clips.length + " klip selesai";

      if (data.finished) {{
        document.getElementById("overall-status").innerText =
          "✅ Semua selesai (" + doneCount + " / " + data.clips.length + ")";
        return;
      }}
      setTimeout(poll, 1000);
    }}
    poll();
  </script>
</body>
</html>
"""


@app.route("/", methods=["GET"])
def index():
    return INDEX_TEMPLATE.format(output_dir=OUTPUT_DIR)


@app.route("/process", methods=["GET", "POST"])
def process():
    if request.method == "GET":
        return redirect(url_for("index"))

    video_path = request.form.get("video_path", "").strip()
    raw_text = request.form.get("raw_text", "")

    if not os.path.isfile(video_path):
        return f"<h2>File tidak ditemukan:</h2><p>{video_path}</p><a href='/'>Kembali</a>", 400

    jobs, errors = parse_lines(raw_text)
    if not jobs:
        msg = "<br>".join(errors) if errors else "Tidak ada baris yang valid."
        return f"<h2>Format tidak valid</h2><p>{msg}</p><a href='/'>Kembali</a>", 400

    session_id = uuid.uuid4().hex[:10]
    clips = []
    for idx, (start, end, title) in enumerate(jobs, start=1):
        safe_title = sanitize_filename(title)
        filename = f"{idx:02d} - {safe_title}.mp4"
        clips.append({
            "filename": filename,
            "start": start,
            "end": end,
            "status": "pending",
            "progress": 0,
            "log": "",
            "download_url": url_for("download_file", session_id=session_id, filename=filename),
        })

    with JOBS_LOCK:
        JOBS[session_id] = {
            "video_path": video_path,
            "clips": clips,
            "finished": False,
            "fatal_error": None,
            "created": time.time(),
        }

    thread = threading.Thread(target=run_job, args=(session_id, video_path), daemon=True)
    thread.start()

    return redirect(url_for("status_page", session_id=session_id))


@app.route("/status/<session_id>")
def status_page(session_id):
    if session_id not in JOBS:
        return redirect(url_for("index"))
    return STATUS_TEMPLATE.format(session_id=session_id)


@app.route("/api/status/<session_id>")
def api_status(session_id):
    state = JOBS.get(session_id)
    if not state:
        return jsonify({"error": "session tidak ditemukan"}), 404
    return jsonify({
        "finished": state["finished"],
        "fatal_error": state["fatal_error"],
        "clips": state["clips"],
    })


@app.route("/output/<session_id>/<path:filename>")
def download_file(session_id, filename):
    folder = os.path.join(OUTPUT_DIR, session_id)
    return send_from_directory(folder, filename, as_attachment=False)


if __name__ == "__main__":
    threading.Thread(target=cleanup_old_outputs, daemon=True).start()
    app.run(host="0.0.0.0", port=5000, debug=False)
APPEOF

echo "[5/6] Setup auto-start saat boot (Termux:Boot)..."
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-clipcutter.sh << 'BOOTEOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
cd ~/clipcutter
nohup python app.py > server.log 2>&1 &
BOOTEOF
chmod +x ~/.termux/boot/start-clipcutter.sh

echo "[6/6] Menjalankan server sekarang..."
cd ~/clipcutter
nohup python app.py > server.log 2>&1 &
disown

sleep 1
echo ""
echo "✅ SELESAI!"
echo "Buka browser: http://127.0.0.1:5000"
echo ""
echo "Catatan:"
echo "- Kalau ini HP baru: install juga aplikasi 'Termux:Boot' dari"
echo "  sumber yang sama dengan Termux (F-Droid/Play Store), buka sekali,"
echo "  lalu set baterai Termux & Termux:Boot ke 'Unrestricted'."
echo "- Supaya /storage/emulated/0/... bisa diakses, pastikan izin"
echo "  storage sudah di-Allow saat pop-up muncul tadi."
