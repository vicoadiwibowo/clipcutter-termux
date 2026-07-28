#!/usr/bin/env python3
"""
Bot Telegram untuk Clip Cutter.
Jalan berdampingan dengan app.py (server Flask di 127.0.0.1:5000),
menghubungkan menu tombol Telegram ke proses potong video.

Setup:
  pip install python-telegram-bot requests --break-system-packages

Jalankan:
  export BOT_TOKEN="isi_token_dari_BotFather"
  python bot.py
"""

import os
import io
import re
import asyncio
import requests

from telegram import ReplyKeyboardMarkup, ReplyKeyboardRemove, Update
from telegram.ext import (
    Application,
    CommandHandler,
    ConversationHandler,
    MessageHandler,
    ContextTypes,
    filters,
)

# ---------- Konfigurasi ----------

FLASK_BASE_URL = "http://127.0.0.1:5000"
BOT_TOKEN = os.environ.get("BOT_TOKEN", "").strip()

if not BOT_TOKEN:
    token_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot_token.txt")
    if os.path.isfile(token_file):
        BOT_TOKEN = open(token_file, encoding="utf-8").read().strip()

# State ConversationHandler
MAIN_MENU, ASK_PATH, ASK_TIMESTAMPS, ASK_SRT = range(4)

# Simpan session_id terakhir per chat_id (untuk fitur "Cek Status")
LAST_SESSION = {}

BTN_POTONG = "âï¸ Potong Video Baru"
BTN_STATUS = "ð Cek Status"
BTN_BATAL = "â Batal"
BTN_LEWATI = "â­ï¸ Lewati (Tanpa Subtitle)"

MAIN_KEYBOARD = ReplyKeyboardMarkup(
    [[BTN_POTONG, BTN_STATUS], [BTN_BATAL]],
    resize_keyboard=True,
)

SRT_KEYBOARD = ReplyKeyboardMarkup(
    [[BTN_LEWATI], [BTN_BATAL]],
    resize_keyboard=True,
)


# ---------- Util komunikasi ke Flask ----------

def _submit_job(video_path: str, raw_text: str, srt_bytes: bytes = None, srt_filename: str = None):
    """Panggil endpoint /process, return session_id atau None kalau gagal."""
    files = None
    if srt_bytes:
        files = {"srt_file": (srt_filename or "subtitle.srt", srt_bytes, "text/plain")}

    resp = requests.post(
        f"{FLASK_BASE_URL}/process",
        data={"video_path": video_path, "raw_text": raw_text},
        files=files,
        allow_redirects=True,
        timeout=30,
    )
    if resp.status_code != 200:
        return None, f"Server menolak (HTTP {resp.status_code}). Cek path video & format daftar potongan."

    match = re.search(r"/status/([a-f0-9]+)", resp.url)
    if not match:
        return None, "Tidak bisa membaca session_id dari respons server."
    return match.group(1), None


def _get_status(session_id: str):
    resp = requests.get(f"{FLASK_BASE_URL}/api/status/{session_id}", timeout=15)
    if resp.status_code != 200:
        return None
    return resp.json()


def _download_clip_bytes(download_url: str):
    resp = requests.get(f"{FLASK_BASE_URL}{download_url}", timeout=120)
    resp.raise_for_status()
    return resp.content


# ---------- Handler ----------

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    await update.message.reply_text(
        "Halo! Selamat datang di Clip Cutter Bot.\nSilakan pilih menu di bawah.",
        reply_markup=MAIN_KEYBOARD,
    )
    return MAIN_MENU


async def menu_potong(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    await update.message.reply_text(
        "Kirim lokasi lengkap file video-nya.\n\n"
        "Contoh:\n"
        "/storage/emulated/0/snaptube/download/SnapTube Video/nama_video.mp4",
        reply_markup=ReplyKeyboardRemove(),
    )
    return ASK_PATH


async def receive_path(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    video_path = update.message.text.strip()
    context.user_data["video_path"] = video_path
    await update.message.reply_text(
        "Sekarang paste daftar potongannya. Format tiap baris:\n"
        "HH:MM:SS-HH:MM:SS Judul Klip\n\n"
        "Contoh:\n"
        "00:03:52-00:04:36 Akar Masalah Semua Bisnis"
    )
    return ASK_TIMESTAMPS


async def receive_timestamps(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    context.user_data["raw_text"] = update.message.text
    await update.message.reply_text(
        "Ada file subtitle .srt yang mau di-burn ke klip?\n\n"
        "Kirim file .srt sekarang, atau tekan 'Lewati' kalau tidak pakai subtitle.",
        reply_markup=SRT_KEYBOARD,
    )
    return ASK_SRT


async def receive_srt_file(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    document = update.message.document
    if not document.file_name.lower().endswith(".srt"):
        await update.message.reply_text(
            "File itu bukan .srt. Kirim file .srt yang benar, atau tekan 'Lewati'."
        )
        return ASK_SRT

    tg_file = await document.get_file()
    file_bytes = await tg_file.download_as_bytearray()

    await update.message.reply_text("Subtitle diterima. Memulai proses...", reply_markup=MAIN_KEYBOARD)
    await start_processing(
        update, context,
        srt_bytes=bytes(file_bytes), srt_filename=document.file_name,
    )
    return MAIN_MENU


async def skip_srt(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    await update.message.reply_text("Oke, tanpa subtitle. Memulai proses...", reply_markup=MAIN_KEYBOARD)
    await start_processing(update, context, srt_bytes=None, srt_filename=None)
    return MAIN_MENU


async def start_processing(update: Update, context: ContextTypes.DEFAULT_TYPE, srt_bytes=None, srt_filename=None):
    video_path = context.user_data.get("video_path", "")
    raw_text = context.user_data.get("raw_text", "")
    chat_id = update.effective_chat.id

    status_msg = await update.message.reply_text("â³ Mengirim ke server...")

    session_id, err = await asyncio.to_thread(
        _submit_job, video_path, raw_text, srt_bytes, srt_filename
    )
    if not session_id:
        await status_msg.edit_text(f"â Gagal memulai proses.\n{err}")
        return

    LAST_SESSION[chat_id] = session_id
    await status_msg.edit_text(f"â Diterima. Memproses klip...\nSession: {session_id}")

    asyncio.create_task(watch_job(context, chat_id, session_id, status_msg.message_id))

    await update.message.reply_text(
        "Proses berjalan di latar belakang. Kamu akan diberi tahu begitu selesai.\n"
        "Bisa juga cek manual lewat menu ð Cek Status."
    )


async def watch_job(context: ContextTypes.DEFAULT_TYPE, chat_id: int, session_id: str, status_message_id: int):
    bot = context.bot
    last_text = ""

    while True:
        data = await asyncio.to_thread(_get_status, session_id)
        if data is None:
            await asyncio.sleep(3)
            continue

        if data.get("fatal_error"):
            await bot.edit_message_text(
                chat_id=chat_id, message_id=status_message_id,
                text=f"â Gagal: {data['fatal_error']}",
            )
            return

        clips = data.get("clips", [])
        done = sum(1 for c in clips if c["status"] in ("done", "error"))
        text = f"â³ Memproses klip... {done}/{len(clips)} selesai"
        if text != last_text:
            try:
                await bot.edit_message_text(chat_id=chat_id, message_id=status_message_id, text=text)
                last_text = text
            except Exception:
                pass

        if data.get("finished"):
            break
        await asyncio.sleep(3)

    # Kirim tiap klip yang berhasil sebagai video ke chat
    ok_count = 0
    for clip in clips:
        if clip["status"] != "done":
            continue
        try:
            video_bytes = await asyncio.to_thread(_download_clip_bytes, clip["download_url"])
            if len(video_bytes) > 49 * 1024 * 1024:
                await bot.send_message(
                    chat_id=chat_id,
                    text=f"â ï¸ {clip['filename']} terlalu besar untuk dikirim via Telegram (>49MB).",
                )
                continue
            await bot.send_video(
                chat_id=chat_id,
                video=io.BytesIO(video_bytes),
                filename=clip["filename"],
                caption=clip["filename"],
                supports_streaming=True,
            )
            ok_count += 1
        except Exception as e:
            await bot.send_message(chat_id=chat_id, text=f"â ï¸ Gagal kirim {clip['filename']}: {e}")

    await bot.edit_message_text(
        chat_id=chat_id, message_id=status_message_id,
        text=f"â Semua selesai! {ok_count}/{len(clips)} klip terkirim.",
    )


async def menu_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    chat_id = update.effective_chat.id
    session_id = LAST_SESSION.get(chat_id)
    if not session_id:
        await update.message.reply_text("Belum ada proses yang pernah dijalankan dari chat ini.")
        return MAIN_MENU

    data = await asyncio.to_thread(_get_status, session_id)
    if not data:
        await update.message.reply_text("Session tidak ditemukan (mungkin sudah kadaluarsa/dihapus).")
        return MAIN_MENU

    clips = data.get("clips", [])
    lines = [f"Session: {session_id}"]
    for c in clips:
        icon = {"pending": "â³", "processing": "ð", "done": "â", "error": "â"}.get(c["status"], "?")
        lines.append(f"{icon} {c['filename']} ({c['progress']}%)")
    await update.message.reply_text("\n".join(lines))
    return MAIN_MENU


async def menu_batal(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    context.user_data.clear()
    await update.message.reply_text("Dibatalkan. Kembali ke menu utama.", reply_markup=MAIN_KEYBOARD)
    return MAIN_MENU


async def fallback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    await update.message.reply_text("Silakan pilih menu di bawah.", reply_markup=MAIN_KEYBOARD)
    return MAIN_MENU


def main():
    if not BOT_TOKEN:
        raise SystemExit(
            "BOT_TOKEN belum diset. Jalankan:\n"
            "  export BOT_TOKEN='isi_token_dari_BotFather'\n"
            "atau simpan token ke file ~/clipcutter/bot_token.txt"
        )

    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[CommandHandler("start", cmd_start)],
        states={
            MAIN_MENU: [
                MessageHandler(filters.Regex(f"^{re.escape(BTN_POTONG)}$"), menu_potong),
                MessageHandler(filters.Regex(f"^{re.escape(BTN_STATUS)}$"), menu_status),
                MessageHandler(filters.Regex(f"^{re.escape(BTN_BATAL)}$"), menu_batal),
                MessageHandler(filters.TEXT & ~filters.COMMAND, fallback),
            ],
            ASK_PATH: [
                MessageHandler(filters.Regex(f"^{re.escape(BTN_BATAL)}$"), menu_batal),
                MessageHandler(filters.TEXT & ~filters.COMMAND, receive_path),
            ],
            ASK_TIMESTAMPS: [
                MessageHandler(filters.Regex(f"^{re.escape(BTN_BATAL)}$"), menu_batal),
                MessageHandler(filters.TEXT & ~filters.COMMAND, receive_timestamps),
            ],
            ASK_SRT: [
                MessageHandler(filters.Regex(f"^{re.escape(BTN_BATAL)}$"), menu_batal),
                MessageHandler(filters.Regex(f"^{re.escape(BTN_LEWATI)}$"), skip_srt),
                MessageHandler(filters.Document.ALL, receive_srt_file),
                MessageHandler(filters.Regex(r"(?i)^(skip|lewati)$"), skip_srt),
            ],
        },
        fallbacks=[CommandHandler("start", cmd_start)],
    )

    app.add_handler(conv)
    print("Bot Telegram Clip Cutter berjalan...")
    app.run_polling()


if __name__ == "__main__":
    main()