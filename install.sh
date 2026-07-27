#!/data/data/com.termux/files/usr/bin/bash

echo "🎬 Clip Cutter - Auto Installer (Revisi)"
echo "========================================"

# Hapus 'set -e' agar peringatan kecil saat update apt tidak mematikan script
# set -e 

echo "[1/6] Update & install paket (python, ffmpeg, git)..."
# Tambahkan parameter Dpkg::Options agar update berjalan mulus tanpa prompt Y/N
pkg update -y -o Dpkg::Options::="--force-confnew"
pkg install -y python ffmpeg git

echo "[2/6] Setup Virtual Environment & Install Flask..."
mkdir -p ~/clipcutter
cd ~/clipcutter

# Menggunakan venv untuk mengatasi error "externally-managed-environment" di Termux baru
python -m venv venv
~/clipcutter/venv/bin/pip install --upgrade pip
~/clipcutter/venv/bin/pip install flask

echo "[3/6] Setup akses storage..."
# Dijalankan di background agar tidak menghentikan alur instalasi via curl
termux-setup-storage &
sleep 2

echo "[4/6] Menulis app.py versi terbaru ke ~/clipcutter ..."
cat > ~/clipcutter/app.py << 'APPEOF'
#!/usr/bin/env python3
"""
Clip Cutter Web - untuk dijalankan di Termux
Potong video berdasarkan daftar timestamp yang di-paste,
dengan audio & video presisi (sinkron, tidak telat),
progress % real-time per klip, preview video di web,
dan fitur upload manual subtitle (.srt) agar kebal dari blokir YouTube.
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

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
os.makedirs(OUTPUT_DIR, exist_ok=True)

LINE_PATTERN = re.compile(
    r"^\s*(\d{2}:\d{2}:\d{2})\s*-\s*(\d{2}:\d{2}:\d{2})\s+(.+?)\s*$"
)
SRT_TIME_PATTERN = re.compile(
    r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})"
)

JOBS = {}
JOBS_LOCK = threading.Lock()

MAX_AGE_SECONDS = 24 * 60 * 60
CLEANUP_INTERVAL_SECONDS = 30 * 60

# ---------- Util dasar ----------

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

def to_seconds(hms: str) -> float:
    h, m, s = hms.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)

def probe_square_size(path: str, default: int = 1080) -> int:
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height",
        "-of", "csv=p=0",
        path,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        w_str, h_str = result.stdout.strip().split(",")
        w, h = int(w_str), int(h_str)
        return min(w, h)
    except Exception:
        return default

# ---------- Subtitle: Parsing (.srt) ----------

def parse_srt(path: str):
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except Exception as e:
        print(f"Error membaca file srt: {e}")
        return []

    entries = []
    blocks = re.split(r"\n\s*\n", text.strip())
    for block in blocks:
        lines = block.strip().splitlines()
        if len(lines) < 2:
            continue
        match = None
        idx = 0
        for i, line in enumerate(lines):
            match = SRT_TIME_PATTERN.search(line)
            if match:
                idx = i
                break
        if not match:
            continue
        h1, m1, s1, ms1, h2, m2, s2, ms2 = map(int, match.groups())
        start = h1 * 3600 + m1 * 60 + s1 + ms1 / 1000
        end = h2 * 3600 + m2 * 60 + s2 + ms2 / 1000
        text_lines = [l for l in lines[idx + 1:] if l.strip()]
        if text_lines:
            entries.append((start, end, "\n".join(text_lines)))
    return entries

# ---------- Subtitle: Build .ass presisi per klip ----------

def _format_ass_time(t: float) -> str:
    t = max(0.0, t)
    h = int(t // 3600); t -= h * 3600
    m = int(t // 60); t -= m * 60
    s = int(t)
    cs = int(round((t - s) * 100))
    if cs >= 100:
        cs = 0
        s += 1
    return f"{h:01d}:{m:02d}:{s:02d}.{cs:02d}"

def _escape_ass_text(text: str) -> str:
    text = text.replace("\\", "\\\\")
    text = text.replace("{", "\\{").replace("}", "\\}")
    text = text.replace("\n", "\\N")
    return text

def build_clip_ass(entries, clip_start_sec, clip_end_sec, out_path, square_size=1080):
    fontsize = max(20, round(square_size * 0.044))
    marginv = round(square_size * 0.075)
    margin_lr = round(square_size * 0.055)
    outline = max(2, round(square_size * 0.0028))
    shadow = 1

    header = (
        "[Script Info]\n"
        "ScriptType: v4.00+\n"
        f"PlayResX: {square_size}\n"
        f"PlayResY: {square_size}\n"
        "WrapStyle: 0\n"
        "ScaledBorderAndShadow: yes\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
        "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
        "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        f"Style: Default,Arial,{fontsize},&H00FFFFFF,&H000000FF,&H00000000,"
        f"&H00000000,1,0,0,0,100,100,0,0,1,{outline},{shadow},2,"
        f"{margin_lr},{margin_lr},{marginv},1\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    )

    lines = [header]
    count = 0
    for start, end, text in entries:
        if end <= clip_start_sec or start >= clip_end_sec:
            continue
        rel_start = max(start, clip_start_sec) - clip_start_sec
        rel_end = min(end, clip_end_sec) - clip_start_sec
        if rel_end <= rel_start:
            continue
        count += 1
        ass_text = _escape_ass_text(text)
        lines.append(
            f"Dialogue: 0,{_format_ass_time(rel_start)},{_format_ass_time(rel_end)},"
            f"Default,,0,0,0,,{ass_text}\n"
        )

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("".join(lines))
    return count

def escape_for_ffmpeg_filter(path: str) -> str:
    return path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")

# ---------- Pemotongan video ----------

def _run_ffmpeg_with_progress(cmd, duration, on_progress):
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

CROP_1TO1 = (
    "crop="
    "w='min(iw\\,ih)':h='min(iw\\,ih)':"
    "x='(iw-min(iw\\,ih))/2':y='(ih-min(iw\\,ih))/2'"
)

WATERMARK_TEXT = "@omah_cliperr"
WATERMARK_OPACITY = 0.15

def escape_drawtext(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace(":", "\\:")
        .replace("'", "\\'")
        .replace("%", "\\%")
    )

def build_watermark_filter(square_size: int) -> str:
    fontsize = max(18, round(square_size * 0.045))
    escaped = escape_drawtext(WATERMARK_TEXT)
    return (
        f"drawtext=text='{escaped}':"
        f"fontcolor=white@{WATERMARK_OPACITY}:"
        f"fontsize={fontsize}:"
        "x=(w-text_w)/2:y=(h-text_h)/2"
    )

def cut_clip(input_path, start, end, out_path, on_progress, ass_path=None, square_size=1080):
    duration = max(1, to_seconds(end) - to_seconds(start))

    filters = [CROP_1TO1, build_watermark_filter(square_size)]
    has_subtitle = bool(ass_path)
    if has_subtitle:
        escaped = escape_for_ffmpeg_filter(ass_path)
        filters.append(f"subtitles='{escaped}'")
    vf = ",".join(filters)

    cmd = [
        "ffmpeg", "-y",
        "-ss", start,
        "-i", input_path,
        "-t", str(duration),
        "-map", "0:v:0",
        "-map", "0:a:0?",
        "-vf", vf,
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "20",
        "-c:a", "aac",
        "-b:a", "192k",
        "-avoid_negative_ts", "make_zero",
        "-movflags", "+faststart",
        "-progress", "pipe:1",
        "-nostats",
        out_path,
    ]
    return _run_ffmpeg_with_progress(cmd, duration, on_progress)

# ---------- Cleanup otomatis ----------

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
        except Exception:
            pass
        time.sleep(CLEANUP_INTERVAL_SECONDS)

# ---------- Job utama ----------

def run_job(session_id, video_path, full_srt_path):
    state = JOBS[session_id]
    session_dir = os.path.join(OUTPUT_DIR, session_id)

    square_size = probe_square_size(video_path)

    subtitle_entries = None
    if full_srt_path and os.path.exists(full_srt_path):
        subtitle_entries = parse_srt(full_srt_path)
        if subtitle_entries:
            state["subtitle_status"] = "ok"
        else:
            state["subtitle_status"] = "empty"
    else:
        state["subtitle_status"] = "skipped"

    for clip in state["clips"]:
        clip["status"] = "processing"

        def cb(pct, clip=clip):
            clip["progress"] = pct

        out_path = os.path.join(session_dir, clip["filename"])
        start_sec = to_seconds(clip["start"])
        end_sec = to_seconds(clip["end"])

        used_subtitle = False
        clip_ass_path = None
        if subtitle_entries:
            candidate_ass = os.path.join(session_dir, f"{clip['filename']}.ass")
            n_lines = build_clip_ass(
                subtitle_entries, start_sec, end_sec, candidate_ass, square_size=square_size
            )
            if n_lines > 0:
                clip_ass_path = candidate_ass
                used_subtitle = True

        success, log = cut_clip(
            video_path, clip["start"], clip["end"], out_path, cb,
            ass_path=clip_ass_path, square_size=square_size
        )

        clip["has_subtitle"] = used_subtitle
        if success:
            clip["status"] = "done"
            clip["progress"] = 100
        else:
            clip["status"] = "error"
            clip["progress"] = 100
            clip["log"] = log

    state["finished"] = True

# ---------- Template halaman ----------

INDEX_TEMPLATE = """<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Clip Cutter</title>
<style>
  :root {{ --bg:#0f1115; --panel:#171a21; --accent:#4f8cff; --text:#e7e9ee; --muted:#9aa1ac; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; font-family:-apple-system,sans-serif; background:var(--bg); color:var(--text); padding:16px; }}
  h1 {{ font-size:1.3rem; margin-bottom:4px; }}
  p.sub {{ color:var(--muted); margin-top:0; font-size:0.85rem; }}
  .panel {{ background:var(--panel); border-radius:12px; padding:16px; margin-bottom:16px; border:1px solid #262a33; }}
  label {{ display:block; margin-bottom:6px; font-weight:600; font-size:0.9rem; }}
  input[type=text], textarea {{ width:100%; background:#0f1115; color:var(--text); border:1px solid #2c3140; border-radius:8px; padding:10px; font-family:monospace; }}
  textarea {{ min-height:220px; }}
  input[type=file] {{ width:100%; color:var(--text); font-size:0.9rem; padding:6px 0; }}
  button {{ background:var(--accent); color:white; border:none; padding:12px 20px; border-radius:8px; font-size:1rem; font-weight:600; width:100%; margin-top:12px; }}
</style>
</head>
<body>
  <h1>🎬 Clip Cutter</h1>
  <p class="sub">Potong video jadi beberapa klip presisi, format 1:1, audio & video sinkron</p>
  <form method="POST" action="/process" enctype="multipart/form-data">
    <div class="panel">
      <label>Lokasi File Video</label>
      <input type="text" name="video_path" placeholder="/storage/emulated/0/snaptube/download/nama_video.mp4" required>
    </div>
    <div class="panel">
      <label>Upload Subtitle .srt (opsional)</label>
      <input type="file" name="srt_file" accept=".srt">
    </div>
    <div class="panel">
      <label>Paste Daftar Potongan</label>
      <textarea name="raw_text" placeholder="00:03:52-00:04:36 Judul Klip 1" required></textarea>
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
  :root {{ --bg:#0f1115; --panel:#171a21; --accent:#4f8cff; --text:#e7e9ee; --muted:#9aa1ac; --ok:#38c172; --err:#ff5c5c; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; font-family:-apple-system,sans-serif; background:var(--bg); color:var(--text); padding:16px; }}
  .clip {{ background:var(--panel); border-radius:12px; padding:14px; margin-bottom:12px; border:1px solid #262a33; }}
  .bar-bg {{ background:#0f1115; border-radius:6px; height:16px; overflow:hidden; }}
  .bar-fill {{ height:100%; background:var(--accent); width:0%; transition:width .3s; }}
  .bar-fill.done {{ background:var(--ok); }}
  .bar-fill.error {{ background:var(--err); }}
  video {{ width:100%; border-radius:8px; margin-top:10px; background:#000; }}
  a {{ color:var(--accent); text-decoration:none; }}
</style>
</head>
<body>
  <a href="/">← Potong video lain</a>
  <h1 id="overall-status">Menyiapkan...</h1>
  <div id="clips"></div>
  <script>
    const sessionId = "{session_id}";
    async function poll() {{
      const res = await fetch("/api/status/" + sessionId);
      const data = await res.json();
      let html = "";
      data.clips.forEach(c => {{
        let barClass = c.status === "done" ? "done" : (c.status === "error" ? "error" : "");
        html += '<div class="clip"><div>' + c.filename + '</div>' +
          '<div class="bar-bg"><div class="bar-fill ' + barClass + '" style="width:' + c.progress + '%"></div></div>' +
          (c.status === "done" ? '<video controls src="' + c.download_url + '"></video><br><a href="' + c.download_url + '" download>⬇ Download</a>' : '') +
          '</div>';
      }});
      document.getElementById("clips").innerHTML = html;
      if (data.finished) document.getElementById("overall-status").innerText = "✅ Semua selesai";
      else setTimeout(poll, 1000);
    }}
    poll();
  </script>
</body>
</html>
"""

@app.route("/")
def index():
    return INDEX_TEMPLATE

@app.route("/process", methods=["POST"])
def process():
    video_path = request.form.get("video_path", "").strip()
    raw_text = request.form.get("raw_text", "")
    srt_file = request.files.get("srt_file")

    jobs, _ = parse_lines(raw_text)
    session_id = uuid.uuid4().hex[:10]
    session_dir = os.path.join(OUTPUT_DIR, session_id)
    os.makedirs(session_dir, exist_ok=True)

    full_srt_path = None
    if srt_file and srt_file.filename:
        full_srt_path = os.path.join(session_dir, "uploaded_sub.srt")
        srt_file.save(full_srt_path)

    clips = []
    for idx, (start, end, title) in enumerate(jobs, start=1):
        filename = f"{idx:02d} - {sanitize_filename(title)}.mp4"
        clips.append({
            "filename": filename, "start": start, "end": end,
            "status": "pending", "progress": 0, "has_subtitle": False,
            "download_url": url_for("download_file", session_id=session_id, filename=filename),
        })

    with JOBS_LOCK:
        JOBS[session_id] = {"clips": clips, "finished": False, "subtitle_status": "skipped"}

    threading.Thread(target=run_job, args=(session_id, video_path, full_srt_path), daemon=True).start()
    return redirect(url_for("status_page", session_id=session_id))

@app.route("/status/<session_id>")
def status_page(session_id):
    return STATUS_TEMPLATE.format(session_id=session_id)

@app.route("/api/status/<session_id>")
def api_status(session_id):
    return jsonify(JOBS.get(session_id, {}))

@app.route("/output/<session_id>/<path:filename>")
def download_file(session_id, filename):
    return send_from_directory(os.path.join(OUTPUT_DIR, session_id), filename, as_attachment=False)

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
# Menjalankan python dari dalam venv yang sudah dibuat
nohup ~/clipcutter/venv/bin/python app.py > server.log 2>&1 &
BOOTEOF
chmod +x ~/.termux/boot/start-clipcutter.sh

echo "[6/6] Menjalankan server sekarang..."
cd ~/clipcutter
# Eksekusi langsung menggunakan python venv
nohup ~/clipcutter/venv/bin/python app.py > server.log 2>&1 &
disown

sleep 1
echo ""
echo "✅ INSTALASI SELESAI!"
echo "Buka browser: http://127.0.0.1:5000"
