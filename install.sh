#!/data/data/com.termux/files/usr/bin/bash

echo "✨ Clip Cutter Premium - Auto Installer"
echo "========================================"

echo "[1/6] Sinkronisasi & pembersihan Termux (Mencegah error FFmpeg)..."
pkg clean
pkg update -y -o Dpkg::Options::="--force-confnew"
pkg upgrade -y -o Dpkg::Options::="--force-confnew"

echo "[2/6] Install paket utama (python, ffmpeg, git)..."
pkg install -y python ffmpeg git

# Cek apakah FFmpeg terkena isu library (seperti libplacebo.so)
if ! ffmpeg -version > /dev/null 2>&1; then
    echo "⚠️ Terdeteksi error linking pada FFmpeg. Melakukan auto-perbaikan..."
    pkg reinstall -y ffmpeg
fi

echo "[3/6] Setup Virtual Environment & Install Flask..."
mkdir -p ~/clipcutter
cd ~/clipcutter

python -m venv venv
~/clipcutter/venv/bin/pip install --upgrade pip
~/clipcutter/venv/bin/pip install flask

echo "[4/6] Setup akses storage..."
termux-setup-storage &
sleep 2

echo "[5/6] Menulis app.py dengan Tema Premium ke ~/clipcutter ..."
cat > ~/clipcutter/app.py << 'APPEOF'
#!/usr/bin/env python3
"""
Clip Cutter Web - Premium Edition (Termux)
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

LINE_PATTERN = re.compile(r"^\s*(\d{2}:\d{2}:\d{2})\s*-\s*(\d{2}:\d{2}:\d{2})\s+(.+?)\s*$")
SRT_TIME_PATTERN = re.compile(r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})")

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
    jobs, errors = [], []
    for i, line in enumerate(raw_text.splitlines(), start=1):
        if not line.strip(): continue
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
    cmd = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", path]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        w_str, h_str = result.stdout.strip().split(",")
        return min(int(w_str), int(h_str))
    except Exception:
        return default

# ---------- Subtitle ----------
def parse_srt(path: str):
    try: text = open(path, encoding="utf-8", errors="ignore").read()
    except Exception: return []
    entries = []
    blocks = re.split(r"\n\s*\n", text.strip())
    for block in blocks:
        lines = block.strip().splitlines()
        if len(lines) < 2: continue
        match, idx = None, 0
        for i, line in enumerate(lines):
            match = SRT_TIME_PATTERN.search(line)
            if match:
                idx = i
                break
        if not match: continue
        h1, m1, s1, ms1, h2, m2, s2, ms2 = map(int, match.groups())
        start = h1 * 3600 + m1 * 60 + s1 + ms1 / 1000
        end = h2 * 3600 + m2 * 60 + s2 + ms2 / 1000
        text_lines = [l for l in lines[idx + 1:] if l.strip()]
        if text_lines: entries.append((start, end, "\n".join(text_lines)))
    return entries

def _format_ass_time(t: float) -> str:
    t = max(0.0, t)
    h = int(t // 3600); t -= h * 3600
    m = int(t // 60); t -= m * 60
    s = int(t); cs = int(round((t - s) * 100))
    if cs >= 100: cs, s = 0, s + 1
    return f"{h:01d}:{m:02d}:{s:02d}.{cs:02d}"

def _escape_ass_text(text: str) -> str:
    return text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}").replace("\n", "\\N")

def build_clip_ass(entries, clip_start_sec, clip_end_sec, out_path, square_size=1080):
    fontsize = max(20, round(square_size * 0.044))
    marginv = round(square_size * 0.075)
    margin_lr = round(square_size * 0.055)
    outline, shadow = max(2, round(square_size * 0.0028)), 1
    header = (
        "[Script Info]\nScriptType: v4.00+\n"
        f"PlayResX: {square_size}\nPlayResY: {square_size}\n"
        "WrapStyle: 0\nScaledBorderAndShadow: yes\n\n[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        f"Style: Default,Arial,{fontsize},&H00FFFFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,{outline},{shadow},2,{margin_lr},{margin_lr},{marginv},1\n\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    )
    lines, count = [header], 0
    for start, end, text in entries:
        if end <= clip_start_sec or start >= clip_end_sec: continue
        rel_start, rel_end = max(start, clip_start_sec) - clip_start_sec, min(end, clip_end_sec) - clip_start_sec
        if rel_end <= rel_start: continue
        count += 1
        lines.append(f"Dialogue: 0,{_format_ass_time(rel_start)},{_format_ass_time(rel_end)},Default,,0,0,0,,{_escape_ass_text(text)}\n")
    with open(out_path, "w", encoding="utf-8") as f: f.write("".join(lines))
    return count

def escape_for_ffmpeg_filter(path: str) -> str:
    return path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")

# ---------- FFmpeg Engine ----------
def _run_ffmpeg_with_progress(cmd, duration, on_progress):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, bufsize=1)
    stderr_lines = []
    def read_stderr():
        for line in proc.stderr: stderr_lines.append(line)
    t = threading.Thread(target=read_stderr, daemon=True)
    t.start()
    for line in proc.stdout:
        line = line.strip()
        if line.startswith("out_time_ms="):
            try:
                ms = int(line.split("=")[1])
                on_progress(max(0, min(99, int((ms / 1_000_000) / duration * 100))))
            except: pass
        elif line == "progress=end": on_progress(100)
    proc.wait()
    t.join(timeout=2)
    return proc.returncode == 0, "".join(stderr_lines)[-2000:]

CROP_1TO1 = "crop=w='min(iw\\,ih)':h='min(iw\\,ih)':x='(iw-min(iw\\,ih))/2':y='(ih-min(iw\\,ih))/2'"
WATERMARK_TEXT, WATERMARK_OPACITY = "@omah_cliperr", 0.15

def build_watermark_filter(square_size: int) -> str:
    escaped = WATERMARK_TEXT.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'").replace("%", "\\%")
    return f"drawtext=text='{escaped}':fontcolor=white@{WATERMARK_OPACITY}:fontsize={max(18, round(square_size * 0.045))}:x=(w-text_w)/2:y=(h-text_h)/2"

def cut_clip(input_path, start, end, out_path, on_progress, ass_path=None, square_size=1080):
    duration = max(1, to_seconds(end) - to_seconds(start))
    filters = [CROP_1TO1, build_watermark_filter(square_size)]
    if ass_path: filters.append(f"subtitles='{escape_for_ffmpeg_filter(ass_path)}'")
    cmd = [
        "ffmpeg", "-y", "-ss", start, "-i", input_path, "-t", str(duration),
        "-map", "0:v:0", "-map", "0:a:0?", "-vf", ",".join(filters),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-c:a", "aac", "-b:a", "192k", "-avoid_negative_ts", "make_zero",
        "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", out_path
    ]
    return _run_ffmpeg_with_progress(cmd, duration, on_progress)

# ---------- Job Runner ----------
def cleanup_old_outputs():
    while True:
        try:
            now = time.time()
            if os.path.isdir(OUTPUT_DIR):
                for name in os.listdir(OUTPUT_DIR):
                    folder = os.path.join(OUTPUT_DIR, name)
                    if os.path.isdir(folder) and (now - os.path.getmtime(folder) > MAX_AGE_SECONDS):
                        shutil.rmtree(folder, ignore_errors=True)
                        with JOBS_LOCK: JOBS.pop(name, None)
        except: pass
        time.sleep(CLEANUP_INTERVAL_SECONDS)

def run_job(session_id, video_path, full_srt_path):
    state = JOBS[session_id]
    session_dir = os.path.join(OUTPUT_DIR, session_id)
    square_size = probe_square_size(video_path)
    subtitle_entries = None
    if full_srt_path and os.path.exists(full_srt_path):
        subtitle_entries = parse_srt(full_srt_path)
        state["subtitle_status"] = "ok" if subtitle_entries else "empty"
    else: state["subtitle_status"] = "skipped"

    for clip in state["clips"]:
        clip["status"] = "processing"
        def cb(pct, clip=clip): clip["progress"] = pct
        out_path = os.path.join(session_dir, clip["filename"])
        start_sec, end_sec = to_seconds(clip["start"]), to_seconds(clip["end"])
        used_sub, clip_ass = False, None
        if subtitle_entries:
            cand = os.path.join(session_dir, f"{clip['filename']}.ass")
            if build_clip_ass(subtitle_entries, start_sec, end_sec, cand, square_size) > 0:
                clip_ass, used_sub = cand, True
        
        success, log = cut_clip(video_path, clip["start"], clip["end"], out_path, cb, clip_ass, square_size)
        clip["has_subtitle"] = used_sub
        if success:
            clip["status"], clip["progress"] = "done", 100
        else:
            clip["status"], clip["progress"], clip["log"] = "error", 100, log
    state["finished"] = True

# ---------- Premium HTML Templates ----------
PREMIUM_CSS = """
  @import url('https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700&display=swap');
  :root {{
    --bg: #09090b; --surface: rgba(24, 24, 27, 0.6); --border: rgba(255, 255, 255, 0.08);
    --gold: #eab308; --gold-hover: #ca8a04; --gold-dim: rgba(234, 179, 8, 0.15);
    --text: #fafafa; --muted: #a1a1aa; --ok: #22c55e; --err: #ef4444; --radius: 16px;
  }}
  * {{ box-sizing: border-box; font-family: 'Plus Jakarta Sans', sans-serif; margin: 0; padding: 0; }}
  body {{ background: var(--bg); color: var(--text); padding: 24px; padding-bottom: 60px; min-height: 100vh; background-image: radial-gradient(circle at top right, var(--gold-dim), transparent 500px); }}
  .container {{ max-width: 600px; margin: 0 auto; }}
  h1 {{ font-size: 1.8rem; font-weight: 700; margin-bottom: 6px; display: flex; align-items: center; gap: 10px; }}
  h1 span {{ background: linear-gradient(to right, #fff, var(--gold)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }}
  p.sub {{ color: var(--muted); font-size: 0.9rem; margin-bottom: 24px; line-height: 1.5; }}
  .panel {{ background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 20px; margin-bottom: 20px; backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2); }}
  label {{ display: block; margin-bottom: 10px; font-weight: 600; font-size: 0.9rem; color: #e4e4e7; }}
  .opt-tag {{ font-size: 0.75rem; background: rgba(255,255,255,0.1); padding: 3px 8px; border-radius: 6px; margin-left: 8px; font-weight: 500; }}
  input[type=text], textarea, input[type=file] {{ width: 100%; background: rgba(0,0,0,0.3); color: var(--text); border: 1px solid var(--border); border-radius: 12px; padding: 14px; font-size: 0.95rem; transition: all 0.3s ease; }}
  input[type=text]:focus, textarea:focus {{ outline: none; border-color: var(--gold); box-shadow: 0 0 0 3px var(--gold-dim); background: rgba(0,0,0,0.5); }}
  textarea {{ min-height: 180px; resize: vertical; line-height: 1.6; font-family: 'Courier New', Courier, monospace; }}
  input[type=file]::file-selector-button {{ background: #27272a; color: white; border: 1px solid var(--border); padding: 8px 16px; border-radius: 8px; cursor: pointer; margin-right: 14px; font-weight: 600; transition: all 0.2s; }}
  input[type=file]::file-selector-button:hover {{ background: #3f3f46; }}
  button {{ background: linear-gradient(135deg, var(--gold), #d97706); color: #000; border: none; padding: 16px; border-radius: 12px; font-size: 1.05rem; font-weight: 700; cursor: pointer; width: 100%; margin-top: 8px; transition: all 0.2s; box-shadow: 0 4px 16px rgba(234, 179, 8, 0.25); text-transform: uppercase; letter-spacing: 0.5px; }}
  button:hover {{ transform: translateY(-2px); box-shadow: 0 6px 20px rgba(234, 179, 8, 0.4); }}
  .out-info {{ display: inline-flex; align-items: center; font-size: 0.8rem; color: var(--gold); margin-bottom: 24px; padding: 8px 14px; background: var(--gold-dim); border-radius: 8px; border: 1px solid rgba(234, 179, 8, 0.3); }}
  .example {{ font-size: 0.8rem; color: var(--muted); margin-top: 10px; background: rgba(0,0,0,0.2); padding: 10px; border-radius: 8px; border-left: 3px solid var(--gold); }}
"""

INDEX_TEMPLATE = f"""<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Clip Cutter Premium</title>
<style>{PREMIUM_CSS}</style>
</head>
<body>
<div class="container">
  <h1>🎬 <span>Clip Cutter</span></h1>
  <p class="sub">Pemotong video presisi tinggi dengan format 1:1, sinkronisasi audio otomatis, dan integrasi subtitle hardsub.</p>
  <div class="out-info">📁 Output: {{output_dir}}</div>

  <form method="POST" action="/process" enctype="multipart/form-data">
    <div class="panel">
      <label>Lokasi File Video</label>
      <input type="text" name="video_path" placeholder="/storage/emulated/0/Download/nama_video.mp4" required>
    </div>
    
    <div class="panel">
      <label>Subtitle Hardsub (.srt) <span class="opt-tag">Opsional</span></label>
      <input type="file" name="srt_file" accept=".srt">
      <div class="example">Upload file .srt untuk ditempel permanen pada video. Posisi presisi.</div>
    </div>
    
    <div class="panel">
      <label>Daftar Potongan Timestamp</label>
      <textarea name="raw_text" placeholder="00:03:52-00:04:36 Intro Klip 1&#10;00:33:48-00:35:10 Momen Epik" required></textarea>
      <div class="example">Format Wajib:<br>HH:MM:SS-HH:MM:SS Nama Judul File</div>
    </div>
    
    <button type="submit">Mulai Eksekusi</button>
  </form>
</div>
</body>
</html>
"""

STATUS_TEMPLATE = f"""<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Memproses... | Clip Cutter</title>
<style>
  {PREMIUM_CSS}
  .clip {{ display: flex; flex-direction: column; }}
  .clip-header {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }}
  .clip-title {{ font-weight: 600; font-size: 1rem; color: var(--text); display: flex; align-items: center; gap: 8px; }}
  .clip-time {{ font-size: 0.8rem; color: var(--muted); background: rgba(255,255,255,0.1); padding: 4px 8px; border-radius: 6px; }}
  .badge {{ font-size: 0.65rem; background: var(--gold-dim); color: var(--gold); padding: 3px 8px; border-radius: 12px; border: 1px solid rgba(234,179,8,0.3); text-transform: uppercase; letter-spacing: 0.5px; font-weight: 700; }}
  .bar-bg {{ background: rgba(0,0,0,0.5); border-radius: 8px; height: 10px; overflow: hidden; border: 1px solid rgba(255,255,255,0.05); }}
  .bar-fill {{ height: 100%; background: linear-gradient(90deg, var(--gold), #fef08a); width: 0%; transition: width 0.4s ease; border-radius: 8px; box-shadow: 0 0 10px rgba(234,179,8,0.4); }}
  .bar-fill.done {{ background: linear-gradient(90deg, var(--ok), #86efac); box-shadow: 0 0 10px rgba(34,197,94,0.4); }}
  .bar-fill.error {{ background: linear-gradient(90deg, var(--err), #fca5a5); }}
  .status-text {{ font-size: 0.8rem; margin-top: 8px; color: var(--muted); font-weight: 500; }}
  video {{ width: 100%; border-radius: 12px; margin-top: 16px; border: 1px solid var(--border); box-shadow: 0 4px 12px rgba(0,0,0,0.3); background: #000; }}
  .dl-btn {{ display: block; margin-top: 12px; text-align: center; background: rgba(255,255,255,0.05); color: var(--text); text-decoration: none; font-weight: 600; padding: 14px; border-radius: 10px; transition: all 0.2s; border: 1px solid var(--border); }}
  .dl-btn:hover {{ background: rgba(255,255,255,0.1); border-color: rgba(255,255,255,0.2); }}
  .back-btn {{ display: inline-flex; align-items: center; color: var(--muted); text-decoration: none; font-size: 0.9rem; margin-bottom: 20px; font-weight: 500; transition: color 0.2s; }}
  .back-btn:hover {{ color: var(--text); }}
  .sub-status {{ font-size: 0.85rem; padding: 10px 14px; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 20px; display: inline-block; }}
</style>
</head>
<body>
<div class="container">
  <a href="/" class="back-btn">← Kembali</a>
  <h1>Status Pemrosesan</h1>
  <p class="sub" id="overall-status">Menyiapkan *engine* rendering...</p>
  <div id="subtitle-info"></div>
  <div id="clips"></div>
</div>

<script>
  const sessionId = "{{session_id}}";
  const subMsg = {{ skipped: "", ok: "✅ Subtitle Terdeteksi & Diproses", empty: "⚠️ Subtitle Kosong / Format Salah" }};
  
  async function poll() {{
    const res = await fetch("/api/status/" + sessionId);
    const data = await res.json();
    
    if (data.subtitle_status && subMsg[data.subtitle_status]) {{
        document.getElementById("subtitle-info").innerHTML = `<div class="sub-status">${{subMsg[data.subtitle_status]}}</div>`;
    }}

    let doneCount = 0; let html = "";
    data.clips.forEach(c => {{
      if (c.status === "done" || c.status === "error") doneCount++;
      let fillClass = c.status === "done" ? "done" : (c.status === "error" ? "error" : "");
      let stLabel = {{ pending: "Menunggu Antrean...", processing: `Merender... ${{c.progress}}%`, done: "✅ Selesai", error: "❌ Gagal" }}[c.status];
      
      html += `<div class="panel clip">
        <div class="clip-header">
          <div class="clip-title">${{c.filename}} ${{c.has_subtitle ? '<span class="badge">CC</span>' : ''}}</div>
          <div class="clip-time">${{c.start}} - ${{c.end}}</div>
        </div>
        <div class="bar-bg"><div class="bar-fill ${{fillClass}}" style="width:${{c.progress}}%"></div></div>
        <div class="status-text">${{stLabel}}</div>
        ${{c.status === "done" ? `<video controls preload="metadata" src="${{c.download_url}}"></video><a class="dl-btn" href="${{c.download_url}}" download>⬇ Simpan ke Perangkat</a>` : ''}}
      </div>`;
    }});
    
    document.getElementById("clips").innerHTML = html;
    document.getElementById("overall-status").innerText = `Progres: ${{doneCount}} dari ${{data.clips.length}} klip selesai`;
    
    if (!data.finished) setTimeout(poll, 1000);
    else document.getElementById("overall-status").innerText = "✅ Seluruh proses rendering telah selesai.";
  }}
  poll();
</script>
</body>
</html>
"""

@app.route("/")
def index(): return INDEX_TEMPLATE.format(output_dir=OUTPUT_DIR)

@app.route("/process", methods=["POST"])
def process():
    video_path = request.form.get("video_path", "").strip()
    raw_text = request.form.get("raw_text", "")
    srt_file = request.files.get("srt_file")
    jobs, _ = parse_lines(raw_text)
    session_id = uuid.uuid4().hex[:10]
    session_dir = os.path.join(OUTPUT_DIR, session_id)
    os.makedirs(session_dir, exist_ok=True)
    full_srt_path = os.path.join(session_dir, "uploaded_sub.srt") if (srt_file and srt_file.filename) else None
    if full_srt_path: srt_file.save(full_srt_path)
    
    clips = [{"filename": f"{i:02d} - {sanitize_filename(t)}.mp4", "start": s, "end": e, "status": "pending", "progress": 0, "has_subtitle": False, "download_url": url_for("download_file", session_id=session_id, filename=f"{i:02d} - {sanitize_filename(t)}.mp4")} for i, (s, e, t) in enumerate(jobs, 1)]
    with JOBS_LOCK: JOBS[session_id] = {"clips": clips, "finished": False, "subtitle_status": "skipped"}
    threading.Thread(target=run_job, args=(session_id, video_path, full_srt_path), daemon=True).start()
    return redirect(url_for("status_page", session_id=session_id))

@app.route("/status/<session_id>")
def status_page(session_id): return STATUS_TEMPLATE.replace("{{session_id}}", session_id)

@app.route("/api/status/<session_id>")
def api_status(session_id): return jsonify(JOBS.get(session_id, {}))

@app.route("/output/<session_id>/<path:filename>")
def download_file(session_id, filename): return send_from_directory(os.path.join(OUTPUT_DIR, session_id), filename, as_attachment=False)

if __name__ == "__main__":
    threading.Thread(target=cleanup_old_outputs, daemon=True).start()
    app.run(host="0.0.0.0", port=5000, debug=False)
APPEOF

echo "[6/6] Menjalankan Auto-Start & Server..."
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-clipcutter.sh << 'BOOTEOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
cd ~/clipcutter
nohup ~/clipcutter/venv/bin/python app.py > server.log 2>&1 &
BOOTEOF
chmod +x ~/.termux/boot/start-clipcutter.sh

cd ~/clipcutter
nohup ~/clipcutter/venv/bin/python app.py > server.log 2>&1 &
disown

sleep 2
echo ""
echo "✅ INSTALASI PREMIUM SELESAI!"
echo "Buka browser: http://127.0.0.1:5000"
