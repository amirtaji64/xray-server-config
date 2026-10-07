# Xray server config (VLESS + WebSocket + Cloudflare + WARP)

راه‌اندازی دوباره سرور VPN روی یک ویندوز سرور جدید، با یک اسکریپت.

## معماری

```
کلاینت (v2rayN / موبایل)
   │  VLESS + WS + TLS  (fingerprint: firefox)
   ▼
Cloudflare  (node.helpforyou.ir، ابر نارنجی، SSL: Flexible)
   │  HTTP پورت 80
   ▼
ویندوز سرور  ── Xray
   ├── geosite:google  ──► Cloudflare WARP (داخل خود Xray، WireGuard)
   └── بقیه ترافیک      ──► مستقیم از IP سرور
```

ترافیک گوگل از WARP عبور می‌کند چون گوگل IP بعضی دیتاسنترها (مثل Hostkey) را تحریمی می‌شناسد و خطای 403 می‌دهد.

## نصب روی سرور جدید

1. روی سرور **PowerShell را با Run as Administrator** باز کنید.
2. ریپازیتوری را دانلود کنید (Code ← Download ZIP) و از حالت فشرده خارج کنید، یا:
   ```powershell
   git clone https://github.com/<USER>/xray-server-config.git C:\xray-server-config
   ```
3. اسکریپت را اجرا کنید. **UUID قبلی را بدهید** تا کانفیگ کلاینت‌ها عوض نشود:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   C:\xray-server-config\server\install.ps1 -Uuid <UUID-قبلی>
   ```
   اسکریپت خودش این کارها را می‌کند:
   - آخرین نسخه Xray را از گیت‌هاب رسمی XTLS دانلود می‌کند و در `C:\Xray` می‌گذارد.
   - یک اکانت رایگان WARP می‌سازد (در `C:\Xray\warp-account.json`).
   - `config.json` را می‌سازد و تست می‌کند.
   - پورت 80 را در فایروال باز می‌کند و تسک `Xray` را برای اجرای خودکار با روشن شدن ویندوز می‌سازد.
4. در **Cloudflare** رکورد `node` را به IP سرور جدید تغییر دهید (ابر نارنجی بماند).

پارامترهای اختیاری: `-WsPath` (پیش‌فرض `/api/v1/stream`)، `-Port` (پیش‌فرض 80)، `-InstallDir` (پیش‌فرض `C:\Xray`)، `-UpdateXray` (به‌روزرسانی Xray)، `-SkipTask`.

> UUID و کلید WARP عمداً در این ریپازیتوری **نیستند**. UUID را جای امنی نگه دارید (مثلاً در پسورد منیجر).

## تنظیمات Cloudflare

| تنظیم | مقدار |
|---|---|
| رکورد DNS | `A node → IP سرور`، **Proxied (ابر نارنجی)** |
| SSL/TLS mode | **Flexible** |
| Network → WebSockets | **On** |

## تنظیمات کلاینت (v2rayN / موبایل)

| فیلد | مقدار |
|---|---|
| Protocol | VLESS |
| Address | `node.helpforyou.ir` |
| Port | `443` |
| UUID | همان UUID سرور |
| Encryption | `none` |
| Transport | `ws` |
| Path | `/api/v1/stream` |
| Host | `node.helpforyou.ir` |
| TLS | `tls` |
| SNI | `node.helpforyou.ir` |
| **Fingerprint** | **`firefox`** |
| ALPN | `http/1.1` |

نمونه لینک: [client/vless-link.template.txt](client/vless-link.template.txt)

> **fingerprint حتماً `firefox` باشد.** بدون آن (یا با `chrome`) اینترنت خانگی (مخابرات) حدود نصف اتصال‌ها را ریست می‌کند. در تست: بدون fingerprint ۳۵ ریست، chrome ۲۵ ریست، firefox صفر.

## مدیریت روزمره روی سرور

| کار | روش |
|---|---|
| ری‌استارت Xray | Task Scheduler ← تسک `XrayRestart` ← Run |
| بررسی اجرا بودن | `Get-Process xray` |
| برگرداندن کانفیگ قبلی | فایل‌های `config-backup-*.json` در `C:\Xray` |
| به‌روزرسانی Xray | `install.ps1 -Uuid <UUID> -UpdateXray` |

## محدودیت شناخته‌شده

Gemini و AI Studio با WARP روی سرورهای Hostkey باز **نمی‌شوند**: گوگل IP خروجی WARP را «روسیه» می‌بیند. برای این دو باید سرور از شرکتی غیر روسی باشد (یا خروجی جداگانه برای این دامنه‌ها). Google Pay و بقیه سرویس‌های گوگل با WARP کار می‌کنند.
