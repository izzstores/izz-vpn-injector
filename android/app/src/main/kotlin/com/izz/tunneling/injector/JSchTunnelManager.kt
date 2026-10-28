package com.izz.tunneling.injector

import android.net.VpnService
import android.os.Build
import android.util.Log
import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import com.jcraft.jsch.SocketFactory
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Properties
import java.util.concurrent.atomic.AtomicBoolean
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
    private var socksServer: ServerSocket? = null
    private val isRunning = AtomicBoolean(false)

    fun start() {
        if (isRunning.get()) return
        isRunning.set(true)

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
                session = sess

                // Start In-Process SOCKS5 Proxy Server on 127.0.0.1:10808
                startSocks5Server(sess)

                onLog("SOCKS5 Proxy Siap pada 127.0.0.1:$LOCAL_SOCKS_PORT!")
                onConnected()

                // Keep session alive
                while (isRunning.get() && sess.isConnected) {
                    Thread.sleep(2000)
                }

                if (isRunning.get() && !sess.isConnected) {
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

    private fun startSocks5Server(sshSession: Session) {
        socksServer = ServerSocket(LOCAL_SOCKS_PORT, 50, InetAddress.getByName("127.0.0.1"))

        Thread {
            while (isRunning.get() && socksServer != null && !socksServer!!.isClosed) {
                try {
                    val client = socksServer!!.accept()
                    Thread {
                        handleSocksClient(client, sshSession)
                    }.apply {
                        name = "socks5-client"
                        isDaemon = true
                        start()
                    }
                } catch (e: Exception) {
                    if (!isRunning.get()) break
                }
            }
        }.apply {
            name = "socks5-listener"
            isDaemon = true
            start()
        }
    }

    private fun handleSocksClient(client: Socket, sshSession: Session) {
        var channel: ChannelDirectTCPIP? = null
        try {
            val dis = DataInputStream(client.getInputStream())
            val dos = DataOutputStream(client.getOutputStream())

            // 1. SOCKS5 Auth Handshake
            val ver = dis.readUnsignedByte()
            if (ver != 5) {
                client.close()
                return
            }
            val nmethods = dis.readUnsignedByte()
            val methods = ByteArray(nmethods)
            dis.readFully(methods)

            // Reply: Version 5, Method 0 (No Auth)
            dos.writeByte(5)
            dos.writeByte(0)
            dos.flush()

            // 2. SOCKS5 Connect Request
            val reqVer = dis.readUnsignedByte()
            val cmd = dis.readUnsignedByte() // 1 = CONNECT
            val rsv = dis.readUnsignedByte() // 0x00
            val atyp = dis.readUnsignedByte()

            val destHost: String
            if (atyp == 1) { // IPv4
                val ipBytes = ByteArray(4)
                dis.readFully(ipBytes)
                destHost = InetAddress.getByAddress(ipBytes).hostAddress ?: ""
            } else if (atyp == 3) { // Domain name
                val domainLen = dis.readUnsignedByte()
                val domainBytes = ByteArray(domainLen)
                dis.readFully(domainBytes)
                destHost = String(domainBytes, Charsets.UTF_8)
            } else if (atyp == 4) { // IPv6
                val ipBytes = ByteArray(16)
                dis.readFully(ipBytes)
                destHost = InetAddress.getByAddress(ipBytes).hostAddress ?: ""
            } else {
                dos.write(byteArrayOf(5, 8, 0, 1, 0, 0, 0, 0, 0, 0)) // Address type not supported
                dos.flush()
                client.close()
                return
            }

            val destPort = dis.readUnsignedShort()

            if (cmd != 1) { // Only CONNECT is supported
                dos.write(byteArrayOf(5, 7, 0, 1, 0, 0, 0, 0, 0, 0)) // Command not supported
                dos.flush()
                client.close()
                return
            }

            // 3. Open SSH direct-tcpip channel
            val ch = sshSession.openChannel("direct-tcpip") as ChannelDirectTCPIP
            ch.setHost(destHost)
            ch.setPort(destPort)
            ch.connect(8000)

            channel = ch

            // Reply: SOCKS5 Success
            dos.write(byteArrayOf(5, 0, 0, 1, 0, 0, 0, 0, 0, 0))
            dos.flush()

            // 4. Bi-directional stream forwarding
            val clientIn = client.getInputStream()
            val clientOut = client.getOutputStream()
            val sshIn = ch.inputStream
            val sshOut = ch.outputStream

            val t1 = Thread {
                try {
                    val buf = ByteArray(16384)
                    var len = 0
                    while (isRunning.get() && clientIn.read(buf).also { len = it } != -1) {
                        sshOut.write(buf, 0, len)
                        sshOut.flush()
                    }
                } catch (_: Exception) {}
            }

            val t2 = Thread {
                try {
                    val buf = ByteArray(16384)
                    var len = 0
                    while (isRunning.get() && sshIn.read(buf).also { len = it } != -1) {
                        clientOut.write(buf, 0, len)
                        clientOut.flush()
                    }
                } catch (_: Exception) {}
            }

            t1.start()
            t2.start()
            t1.join()
            t2.join()

        } catch (e: Exception) {
            Log.d(TAG, "Socks client error: ${e.message}")
        } finally {
            try { channel?.disconnect() } catch (_: Exception) {}
            try { client.close() } catch (_: Exception) {}
        }
    }

    fun stop() {
        isRunning.set(false)
        try {
            socksServer?.close()
            socksServer = null
        } catch (_: Exception) {}
        try {
            session?.disconnect()
            session = null
            workerThread?.interrupt()
            workerThread = null
        } catch (_: Exception) {}
    }
}
