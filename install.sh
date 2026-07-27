#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO_RAW="https://raw.githubusercontent.com/vicoadiwibowo/clipcutter-termux/main"

echo "Clip Cutter - Auto Installer"
echo "================================"

echo "[1/5] Update & install paket dasar (python, ffmpeg, git)..."
pkg update -y
pkg upgrade -y
pkg install -y python ffmpeg git

echo "[2/5] Install Flask..."
pip install --upgrade pip
pip install flask

echo "[3/5] Setup akses storage (izinkan lewat pop-up yang muncul)..."
termux-setup-storage
sleep 2

echo "[4/5] Mengunduh app.py terbaru dari repo..."
mkdir -p ~/clipcutter
curl -fsSL "$REPO_RAW/app.py" -o ~/clipcutter/app.py

if [ ! -s ~/clipcutter/app.py ]; then
  echo "GAGAL: app.py tidak berhasil diunduh atau kosong. Cek URL repo-nya."
  exit 1
fi

python3 -c "import py_compile; py_compile.compile('$HOME/clipcutter/app.py', doraise=True)" \
  && echo "app.py valid (sintaks OK)" \
  || { echo "GAGAL: app.py yang diunduh punya error sintaks."; exit 1; }

echo "[5/5] Setup auto-start saat boot (Termux:Boot)..."
mkdir -p ~/.termux/boot
BOOT_SCRIPT=~/.termux/boot/start-clipcutter.sh
printf '%s\n' \
  '#!/data/data/com.termux/files/usr/bin/sh' \
  'termux-wake-lock' \
  'cd ~/clipcutter' \
  'nohup python app.py > server.log 2>&1 &' \
  > "$BOOT_SCRIPT"
chmod +x "$BOOT_SCRIPT"

echo "Menjalankan server sekarang..."
pkill -9 -f "python app.py" 2>/dev/null || true
sleep 1
cd ~/clipcutter
nohup python app.py > server.log 2>&1 &
disown

sleep 1
echo ""
echo "SELESAI!"
echo "Buka browser: http://127.0.0.1:5000"
echo ""
echo "Catatan:"
echo "- Kalau ini HP baru: install juga aplikasi 'Termux:Boot' dari"
echo "  sumber yang sama dengan Termux (F-Droid/Play Store), buka sekali,"
echo "  lalu set baterai Termux & Termux:Boot ke 'Unrestricted'."
echo "- Pastikan izin storage sudah di-Allow saat pop-up muncul tadi."
