#!/data/data/com.termux/files/usr/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

REPO_RAW="https://raw.githubusercontent.com/vicoadiwibowo/clipcutter-termux/main"
SELF_URL="$REPO_RAW/install.sh"
CLIPCUTTER_DIR=~/clipcutter

# --------------------------------------------------------------------
# Kalau dijalankan lewat "curl | bash", stdin dipakai buat mengalirkan
# isi script ini sendiri, jadi tidak bisa dipakai buat nanya input
# (misal token bot). Kalau kondisi itu terdeteksi, download ulang diri
# sendiri ke file lalu jalan ulang dengan akses keyboard normal (tty),
# supaya tetap bisa interaktif tanpa kamu perlu ubah cara menjalankannya.
# --------------------------------------------------------------------
if [ ! -t 0 ]; then
  echo "Menyiapkan installer supaya bisa interaktif..."
  curl -fsSL "$SELF_URL" -o /tmp/clipcutter_install.sh
  exec bash /tmp/clipcutter_install.sh < /dev/tty
fi

echo "Clip Cutter - Auto Installer"
echo "================================"

echo "[1/6] Update & install paket dasar (python, ffmpeg, git)..."
yes n | apt-get update -y
yes n | apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
yes n | apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  python ffmpeg git

echo "[2/6] Install Flask & library bot Telegram..."
pip install flask requests python-telegram-bot --break-system-packages 2>/dev/null \
  || pip install flask requests python-telegram-bot

echo "[3/6] Setup akses storage (izinkan lewat pop-up yang muncul)..."
termux-setup-storage
sleep 2

echo "[4/6] Mengunduh app.py & bot.py terbaru dari repo..."
mkdir -p "$CLIPCUTTER_DIR"
curl -fsSL "$REPO_RAW/app.py" -o "$CLIPCUTTER_DIR/app.py"
curl -fsSL "$REPO_RAW/bot.py" -o "$CLIPCUTTER_DIR/bot.py"

for f in app.py bot.py; do
  if [ ! -s "$CLIPCUTTER_DIR/$f" ]; then
    echo "GAGAL: $f tidak berhasil diunduh atau kosong. Cek URL repo-nya."
    exit 1
  fi
  python3 -c "import py_compile; py_compile.compile('$CLIPCUTTER_DIR/$f', doraise=True)" \
    && echo "$f valid (sintaks OK)" \
    || { echo "GAGAL: $f yang diunduh punya error sintaks."; exit 1; }
done

echo "[5/6] Setup token Bot Telegram..."
TOKEN_FILE="$CLIPCUTTER_DIR/bot_token.txt"
if [ -s "$TOKEN_FILE" ]; then
  echo "Token bot sudah ada dari sebelumnya, dipakai lagi."
else
  echo ""
  echo "Buat bot dulu di Telegram lewat @BotFather kalau belum punya,"
  echo "lalu tempel token-nya di sini (boleh dikosongkan & Enter untuk"
  echo "melewati -- nanti bot tidak otomatis jalan sampai token diisi)."
  read -r -p "Bot Token: " BOT_TOKEN_INPUT
  if [ -n "$BOT_TOKEN_INPUT" ]; then
    echo "$BOT_TOKEN_INPUT" > "$TOKEN_FILE"
    echo "Token tersimpan."
  else
    echo "Dilewati. Bot Telegram tidak akan dijalankan otomatis."
  fi
fi

echo "[6/6] Setup auto-start (tiap buka Termux & tiap HP restart)..."

# --- A. Auto-start tiap sesi Termux dibuka (lewat .bashrc) ---
BASHRC=~/.bashrc
MARKER="# >>> clipcutter-autostart >>>"
if ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  cat >> "$BASHRC" << EOF

$MARKER
if ! pgrep -f "app.py" > /dev/null 2>&1; then
  (cd "$CLIPCUTTER_DIR" && nohup python app.py > server.log 2>&1 &)
  echo "Clip Cutter server dijalankan di background (http://127.0.0.1:5000)"
fi
if [ -s "$CLIPCUTTER_DIR/bot_token.txt" ] && ! pgrep -f "bot.py" > /dev/null 2>&1; then
  (cd "$CLIPCUTTER_DIR" && BOT_TOKEN="\$(cat bot_token.txt)" nohup python bot.py > bot.log 2>&1 &)
  echo "Bot Telegram Clip Cutter dijalankan di background"
fi
# <<< clipcutter-autostart <<<
EOF
  echo "Auto-start .bashrc terpasang."
else
  echo "Auto-start .bashrc sudah ada dari sebelumnya, dilewati."
fi

# --- B. Auto-start tiap HP restart (lewat Termux:Boot) ---
mkdir -p ~/.termux/boot
BOOT_SCRIPT=~/.termux/boot/start-clipcutter.sh
{
  echo '#!/data/data/com.termux/files/usr/bin/sh'
  echo 'termux-wake-lock'
  echo "cd $CLIPCUTTER_DIR"
  echo 'nohup python app.py > server.log 2>&1 &'
  echo "if [ -s $CLIPCUTTER_DIR/bot_token.txt ]; then"
  echo "  BOT_TOKEN=\$(cat $CLIPCUTTER_DIR/bot_token.txt) nohup python bot.py > bot.log 2>&1 &"
  echo "fi"
} > "$BOOT_SCRIPT"
chmod +x "$BOOT_SCRIPT"

echo "Menjalankan server & bot sekarang..."
pkill -9 -f "app.py" 2>/dev/null || true
pkill -9 -f "bot.py" 2>/dev/null || true
sleep 1

cd "$CLIPCUTTER_DIR"
nohup python app.py > server.log 2>&1 &
disown

if [ -s "$TOKEN_FILE" ]; then
  BOT_TOKEN="$(cat "$TOKEN_FILE")" nohup python bot.py > bot.log 2>&1 &
  disown
  BOT_STARTED=1
else
  BOT_STARTED=0
fi

sleep 1
echo ""
echo "=================================="
echo "SELESAI!"
echo "=================================="
echo "Web Clip Cutter : http://127.0.0.1:5000"
if [ "$BOT_STARTED" = "1" ]; then
  echo "Bot Telegram    : aktif, coba /start di chat bot kamu"
else
  echo "Bot Telegram    : BELUM aktif (token belum diisi)."
  echo "  Isi nanti dengan:"
  echo "  echo 'TOKEN_KAMU' > $CLIPCUTTER_DIR/bot_token.txt"
  echo "  lalu buka Termux baru, atau jalankan manual:"
  echo "  cd $CLIPCUTTER_DIR && BOT_TOKEN=\$(cat bot_token.txt) python bot.py"
fi
echo ""
echo "Mulai sekarang, setiap kali kamu buka Termux, keduanya akan"
echo "otomatis nyala sendiri di background -- tidak perlu ketik apapun."
echo ""
echo "Catatan:"
echo "- Kalau ini HP baru: install juga aplikasi 'Termux:Boot' dari"
echo "  sumber yang sama dengan Termux (F-Droid/Play Store), buka sekali,"
echo "  lalu set baterai Termux & Termux:Boot ke 'Unrestricted'."
echo "- Pastikan izin storage sudah di-Allow saat pop-up muncul tadi."
