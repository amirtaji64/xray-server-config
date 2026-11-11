# Xray server installer (VLESS + WebSocket + Cloudflare + WARP)

نصب سرور VPN روی یک **ویندوز سرور کاملاً خالی** با **یک دستور**.

## نصب (فقط همین)

روی سرور، **PowerShell را با Run as Administrator** باز کنید و این یک خط را بزنید. فقط `<UUID>` و `<DOMAIN>` را عوض کنید:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/amirtaji64/xray-server-config/main/install.ps1))) -Uuid <UUID> -Domain <DOMAIN>
```

- `<UUID>`: همان UUID که الان در v2rayN دارید. **همیشه همان قبلی را بدهید** تا کلاینت‌ها عوض نشوند.
- `<DOMAIN>`: ساب‌دامنه‌ای که در Cloudflare به سرور اشاره می‌کند. فقط برای ساخت لینک آخر کار است.

به Git یا دانلود zip نیازی نیست. دوباره اجرا کردن دستور هم مشکلی ایجاد نمی‌کند (کانفیگ قبلی بکاپ گرفته می‌شود).

اسکریپت این کارها را انجام می‌دهد:
1. آخرین نسخه رسمی Xray را در `C:\Xray` نصب می‌کند.
2. یک اکانت رایگان Cloudflare WARP می‌سازد و ترافیک گوگل را از آن عبور می‌دهد. اگر این مرحله شکست بخورد، بدون WARP ادامه می‌دهد.
3. `config.json` را با UUID شما می‌سازد و تست می‌کند.
4. پورت 80 را باز می‌کند، هر Xray در حال اجرا را می‌بندد، تسک اجرای خودکار را می‌سازد، Xray را اجرا می‌کند و **بررسی می‌کند که واقعاً روی پورت 80 گوش می‌دهد**.
5. IP سرور و **لینک آماده کلاینت** را چاپ می‌کند.

پارامترهای اختیاری: `-WsPath` (پیش‌فرض `/api/v1/stream`)، `-Port` (پیش‌فرض 80)، `-NoWarp`، `-UpdateXray`، `-InstallDir` (پیش‌فرض `C:\Xray`).

## بعد از نصب: Cloudflare

| تنظیم | مقدار |
|---|---|
| DNS | رکورد `A` ساب‌دامنه به IP سرور جدید (اسکریپت IP را چاپ می‌کند)، **Proxied (ابر نارنجی)** |
| SSL/TLS | **Flexible** |
| Network → WebSockets | **On** |

## کلاینت (v2rayN / موبایل)

لینکی که اسکریپت آخر کار چاپ می‌کند را کپی کنید و در v2rayN با `Ctrl+V` وارد کنید. اگر دستی وارد می‌کنید:

| فیلد | مقدار |
|---|---|
| Address / SNI / Host | دامنه شما |
| Port | `443` |
| Transport | `ws`، Path: `/api/v1/stream` |
| TLS | `tls` |
| **Fingerprint** | **`firefox`** (بدون آن اینترنت خانگی اتصال‌ها را ریست می‌کند) |
| ALPN | `http/1.1` |

## مدیریت روی سرور

Xray **سرویس ویندوز نیست**، یک Scheduled Task به نام `Xray` است. پس `Start-Service xray` کار نمی‌کند.

| کار | دستور |
|---|---|
| روشن است؟ | `Get-Process xray` و `netstat -ano \| findstr :80` |
| ری‌استارت | `Start-ScheduledTask XrayRestart` |
| برگرداندن کانفیگ قبلی | فایل‌های `C:\Xray\config-backup-*.json` |
| به‌روزرسانی Xray | همان دستور نصب + `-UpdateXray` |

## خطاهای رایج

| خطا | علت و راه‌حل |
|---|---|
| کلاینت خطای `-1` می‌دهد | UUID سرور با کلاینت یکی نیست. نصب را با UUID کلاینت دوباره اجرا کنید. |
| `Port 80 is used by ...` | برنامه دیگری (مثلاً IIS) پورت را گرفته. پیام خطا دستور توقفش را می‌گوید. |
| `Run PowerShell as Administrator` | PowerShell را با راست‌کلیک ← Run as Administrator باز کنید. |
| Gemini «کشور پشتیبانی نمی‌شود» | IP سرور یا WARP از نظر گوگل در کشور تحریمی است (مثلاً سرورهای Hostkey). سرور از شرکت دیگری بگیرید یا `-NoWarp` را امتحان کنید. |
