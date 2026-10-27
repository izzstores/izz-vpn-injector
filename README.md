# ✦ IZZ TUNNELING - Android VPN Injector Client (Flutter) ✦

Aplikasi VPN & Injector Android modern dengan arsitektur **Dual-Mode** (Mode Simple Cloud Config 1-Klik + Mode Custom Injector Manual) yang terhubung langsung dengan VPS Backend Autoscript dan dikendalikan penuh melalui **Bot Telegram Admin**.

---

## 🌟 Fitur Utama Aplikasi

1. **Dual-Mode Operation:**
   - **Simple Mode (Cloud 1-Klik):** Menampilkan daftar template config dari VPS yang dikelompokkan berdasarkan kategori provider (*Telkomsel, Indosat, XL-Axis, Smartfren, Game*). Pengguna cukup memasukkan Username & Password lalu klik Konek.
   - **Custom Mode (Manual Injector):** Pengguna mahir dapat menentukan Server, Port, Bug SNI, dan HTTP Payload secara mandiri dengan tag shortcut (`[crlf]`, `[host]`, `[split]`, dll).

2. **Realtime Cloud Synchronization:**
   - Setiap kali admin menambah, mengubah, atau menghapus template lewat Bot Telegram (`/add`, `/list`), semua aplikasi member otomatis tersinkronisasi tanpa perlu update APK.

3. **Anti-Sniffing Security (AES-256-GCM):**
   - Bug SNI dan HTTP Payload dienkripsi di server VPS menggunakan kunci Master Secret Key (`APP_SECRET_KEY`).
   - Aplikasi mendekripsi konfigurasi sensitif langsung di memori RAM sesaat sebelum proses koneksi.
   - Aman dari aplikasi sniffer (*HTTPCanary, Packet Capture, PCAPdroid*).

4. **Multi-Protocol Core (sing-box ready):**
   - Mendukung SSH WebSocket, VMess WS, VLess WS, Trojan WS, dan varian gRPC.

5. **Live Monitoring & In-App Announcement:**
   - Menampilkan Ping (ms), Kecepatan Download/Upload, dan Durasi Koneksi.
   - Menampilkan pop-up pengumuman siaran (*broadcast*) yang dikirimkan admin dari bot Telegram.

---

## 🛠️ Persyaratan Build

- **Flutter SDK:** Version 3.10.0 atau lebih baru (Channel Stable).
- **Android SDK:** Compile SDK 34, Min SDK 21 (Android 5.0 Lollipop ke atas).
- **Java / JDK:** OpenJDK 17.

---

## 🚀 Cara Menjalankan & Membangun APK

### 1. Download Dependencies
```bash
flutter pub get
```

### 2. Jalankan di Emulator / HP (Debug Mode)
```bash
flutter run
```

### 3. Build APK Release Siap Distribusi
```bash
flutter build apk --release
```
File APK yang dihasilkan akan berada di:
`build/app/outputs/flutter-apk/app-release.apk`

---

## ⚙️ Konfigurasi Cloud API & Secret Key

File: `lib/constants/api_endpoints.dart`
```dart
class ApiEndpoints {
  // URL VPS Backend Anda
  static const String baseUrl = "https://rioaja.haikara.biz.id/api/v1";
  static const String templates = "$baseUrl/templates";

  // Master Secret Key (Wajib sama dengan APP_SECRET_KEY di file /etc/izz-injector/.env VPS)
  static const String masterSecretKey =
      "01328905915b4945420cd862dfde5244132604c643c6ea05fc46c41558795637";
}
```

---

## 📬 Dukungan & Author

- **Brand:** IZZ TUNNELING
- **Telegram Support:** [@izzcoyy](https://t.me/izzcoyy)
- **WhatsApp Support:** [wa.me/6282213283021](https://wa.me/6282213283021)
