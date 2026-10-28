package com.izz.tunneling.injector

import android.net.VpnService
import android.os.Build
import android.util.Log
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import com.jcraft.jsch.SocketFactory
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Properties
import javax.net.ssl.*

class JSchTunnelManager(
    private val vpnService: VpnService,
    private val host: String,
    private val port: Int,
    private val user: String,
    private val pass: String,
    private val enableSsl: Boolean,
    private val sni: String,
    private val enablePayload: Boolean,
    private val payload: String,
    private val enableProxy: Boolean,
    private val remoteProxy: String,
    private val onLog: (String) -> Unit,
    private val onConnected: () -> Unit,
    private val onError: (String) -> Unit
) {
    companion object {
        const val TAG = "JSchTunnelManager"
        const val LOCAL_SOCKS_PORT = 10808
    }

    private var session: Session? = null
    private var workerThread: Thread? = null
    private var isRunning = false

    fun start() {
        if (isRunning) return
        isRunning = true

        workerThread = Thread {
            try {
                onLog("Inisialisasi SSH Engine (HTTP Custom JSch Core)...")
                val jsch = JSch()

                val socketFactory = object : SocketFactory {
                    private var currentSocket: Socket? = null

                    override fun createSocket(h: String, p: Int): Socket {
                        val targetHost: String
                        val targetPort: Int

                        if (enableProxy && remoteProxy.isNotBlank()) {
                            val parts = remoteProxy.split(":")
                            targetHost = parts[0].trim()
                            targetPort = if (parts.size > 1) parts[1].trim().toIntOrNull() ?: 8080 else 8080
                            onLog("Menghubungkan ke Remote Proxy $targetHost:$targetPort...")
                        } else {
                            targetHost = host
                            targetPort = port
                            onLog("Menghubungkan ke $targetHost:$targetPort...")
                        }

                        var s = Socket()
                        // Critical: Protect socket so it bypasses VPN interface
                        vpnService.protect(s)
                        s.tcpNoDelay = true
                        s.connect(InetSocketAddress(targetHost, targetPort), 15000)

                        if (enableSsl) {
                            val sniHost = if (sni.isNotBlank()) sni.trim() else host.trim()
                            onLog("Melakukan SSL Handshake (SNI: $sniHost)...")

                            val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
                                override fun getAcceptedIssuers(): Array<X509Certificate>? = null
                                override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) {}
                                override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) {}
                            })
                            val sc = SSLContext.getInstance("TLS")
                            sc.init(null, trustAll, SecureRandom())
                            val sslFactory = sc.socketFactory
                            val sslSocket = sslFactory.createSocket(s, targetHost, targetPort, true) as SSLSocket

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                val params = sslSocket.sslParameters
                                params.serverNames = listOf(SNIHostName(sniHost))
                                sslSocket.sslParameters = params
                            }
                            sslSocket.startHandshake()
                            s = sslSocket
                            onLog("SSL Handshake Berhasil!")
                        }

                        if (enablePayload) {
                            val sniHost = if (sni.isNotBlank()) sni.trim() else host.trim()
                            var finalPayload = payload.trim()
                            if (finalPayload.isBlank()) {
                                finalPayload = "GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]"
                            }

                            finalPayload = finalPayload
                                .replace("[crlf]", "\r\n", ignoreCase = true)
                                .replace("[lf]", "\n", ignoreCase = true)
                                .replace("[cr]", "\r", ignoreCase = true)
                                .replace("[host_port]", "$host:$port", ignoreCase = true)
                                .replace("[host]", sniHost, ignoreCase = true)
                                .replace("[port]", port.toString(), ignoreCase = true)
                                .replace("[ua]", "okhttp/4.9.0", ignoreCase = true)
                                .replace("[protocol]", "HTTP/1.1", ignoreCase = true)

                            onLog("Mengirim HTTP Payload...")
                            val out = s.getOutputStream()
                            out.write(finalPayload.toByteArray(Charsets.UTF_8))
                            out.flush()

                            // Read HTTP response header until \r\n\r\n or \n\n
                            val `in` = s.getInputStream()
                            val headerBuf = StringBuilder()
                            val b = ByteArray(1)
                            while (`in`.read(b) != -1) {
                                headerBuf.append(b[0].toInt().toChar())
                                if (headerBuf.endsWith("\r\n\r\n") || headerBuf.endsWith("\n\n")) {
                                    break
                                }
                                if (headerBuf.length > 8192) break
                            }
                            val firstLine = headerBuf.lines().firstOrNull()?.trim() ?: "HTTP/1.1 200 OK"
                            onLog("Status Respon HTTP: $firstLine")
                        }

                        currentSocket = s
                        return s
                    }

                    override fun getInputStream(socket: Socket): InputStream = socket.getInputStream()
                    override fun getOutputStream(socket: Socket): OutputStream = socket.getOutputStream()
                }

                val sess = jsch.getSession(user, host, port)
                sess.setPassword(pass)
                sess.setSocketFactory(socketFactory)

                val config = Properties()
                config["StrictHostKeyChecking"] = "no"
                config["PreferredAuthentications"] = "password,keyboard-interactive"
                sess.setConfig(config)
                sess.timeout = 20000

                onLog("Melakukan Otentikasi SSH untuk '$user'...")
                sess.connect(20000)

                onLog("SSH Terotentikasi! Server Banner: ${sess.serverVersion}")
                onLog("Membuka Port Forwarding SOCKS5 pada 127.0.0.1:$LOCAL_SOCKS_PORT...")
                sess.setPortForwardingD(LOCAL_SOCKS_PORT)

                session = sess
                onLog("SOCKS5 Proxy Siap!")
                onConnected()

                // Keep session alive
                while (isRunning && sess.isConnected) {
                    Thread.sleep(2000)
                }

                if (isRunning && !sess.isConnected) {
                    onError("Koneksi SSH terputus.")
                }

            } catch (e: Exception) {
                Log.e(TAG, "SSH Connection error", e)
                val msg = e.message ?: e.toString()
                onLog("SSH Error: $msg")
                onError("Gagal konek SSH: $msg")
            }
        }.apply {
            name = "jsch-worker"
            isDaemon = true
            start()
        }
    }

    fun stop() {
        isRunning = false
        try {
            session?.disconnect()
            session = null
            workerThread?.interrupt()
            workerThread = null
        } catch (_: Exception) {}
    }
}
