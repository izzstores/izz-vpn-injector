package com.izz.tunneling.injector

import android.net.VpnService
import android.os.Build
import android.util.Log
import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import com.jcraft.jsch.SocketFactory
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
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
    private val enableProxy: Boolean = false,
    private val remoteProxy: String = "",
    private val enableSlowDns: Boolean = false,
    private val slowDnsNs: String = "",
    private val slowDnsPubkey: String = "",
    private val slowDnsServer: String = "8.8.8.8",
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
    private val errorReported = AtomicBoolean(false)
    @Volatile private var lastProbeFailure = "belum ada hasil probe"

    fun probeFailureReason(): String = lastProbeFailure

    private fun probeFailure(message: String): Boolean {
        lastProbeFailure = message
        reportLog(message)
        return false
    }

    private fun reportLog(message: String) {
        try { onLog(message) } catch (t: Throwable) { Log.w(TAG, "log callback failed", t) }
    }

    private fun reportConnected() {
        try { onConnected() } catch (t: Throwable) { Log.e(TAG, "connected callback failed", t) }
    }

    private fun reportError(message: String) {
        if (!errorReported.compareAndSet(false, true)) return
        try { onError(message.take(240)) } catch (t: Throwable) { Log.e(TAG, "error callback failed", t) }
    }

    fun start() {
        if (!isRunning.compareAndSet(false, true)) return
        errorReported.set(false)

        workerThread = Thread {
            try {
                if (host.isBlank() || user.isBlank() || pass.isBlank() || port !in 1..65535) {
                    reportError("Data SSH tidak lengkap atau port tidak valid")
                    return@Thread
                }
                reportLog("Inisialisasi SSH Engine (HTTP Custom JSch Core)...")
                val jsch = JSch()

                val socketFactory = object : SocketFactory {
                    private var currentSocket: Socket? = null

                    override fun createSocket(h: String, p: Int): Socket {
                        val targetHost: String
                        val targetPort: Int

                        if (enableSlowDns && slowDnsNs.isNotBlank() && slowDnsPubkey.isNotBlank()) {
                            targetHost = "127.0.0.1"
                            targetPort = 7000
                            reportLog("Menggunakan SlowDNS Tunnel (NS: $slowDnsNs, DNS: $slowDnsServer)...")
                        } else if (enableProxy && remoteProxy.isNotBlank()) {
                            val parts = remoteProxy.split(":")
                            targetHost = parts[0].trim()
                            targetPort = if (parts.size > 1) parts[1].trim().toIntOrNull() ?: 8080 else 8080
                            reportLog("Menghubungkan ke Remote Proxy $targetHost:$targetPort...")
                        } else {
                            targetHost = host
                            targetPort = port
                            reportLog("Menghubungkan ke $targetHost:$targetPort...")
                        }

                        var s = Socket()
                        // Critical: Protect socket so it bypasses VPN interface
                        if (targetHost.isBlank() || targetPort !in 1..65535) {
                            throw IllegalArgumentException("Remote proxy/host atau port tidak valid")
                        }
                        s.tcpNoDelay = true
                        s.receiveBufferSize = 256 * 1024
                        s.sendBufferSize = 256 * 1024
                        s.soTimeout = 20000
                        if (!vpnService.protect(s)) {
                            throw IllegalStateException("Socket SSH gagal diproteksi dari VPN")
                        }
                        s.connect(InetSocketAddress(targetHost, targetPort), 15000)

                        if (enableSsl) {
                            val sniHost = if (sni.isNotBlank()) sni.trim() else host.trim()
                            reportLog("Melakukan SSL Handshake (SNI: $sniHost)...")

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
                            reportLog("SSL Handshake Berhasil!")
                        }

                        if (enablePayload) {
                            val sniHost = if (sni.isNotBlank()) sni.trim() else host.trim()
                            var finalPayload = payload.trim()
                            if (finalPayload.isBlank()) {
                                finalPayload = "GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]"
                            }

                            val splitToken = Regex("\\[(split|instant_split|delay_split)\\]", RegexOption.IGNORE_CASE)
                            val delaySplit = Regex("\\[delay_split\\]", RegexOption.IGNORE_CASE).containsMatchIn(finalPayload)
                            finalPayload = finalPayload
                                .replace("[crlf]", "\r\n", ignoreCase = true)
                                .replace("[lfcr]", "\n\r", ignoreCase = true)
                                .replace("[lf]", "\n", ignoreCase = true)
                                .replace("[cr]", "\r", ignoreCase = true)
                                .replace("[host_port]", "$host:$port", ignoreCase = true)
                                .replace("[ssh]", "$host:$port", ignoreCase = true)
                                .replace("[netData]", "CONNECT $host:$port HTTP/1.1", ignoreCase = true)
                                .replace("[host]", sniHost, ignoreCase = true)
                                .replace("[port]", port.toString(), ignoreCase = true)
                                .replace("[ua]", "okhttp/4.9.0", ignoreCase = true)
                                .replace("[protocol]", "HTTP/1.1", ignoreCase = true)
                                .replace(Regex("\\[(raw|real_raw)\\]", RegexOption.IGNORE_CASE), "")

                            reportLog("Mengirim HTTP Payload...")
                            val out = s.getOutputStream()
                            val payloadParts = finalPayload.split(splitToken)
                            payloadParts.forEachIndexed { index, part ->
                                if (part.isNotEmpty()) out.write(part.toByteArray(Charsets.UTF_8))
                                out.flush()
                                if (delaySplit && index < payloadParts.lastIndex) Thread.sleep(200)
                            }

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
                            reportLog("Status Respon HTTP: $firstLine")
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

                reportLog("Melakukan Otentikasi SSH untuk '$user'...")
                sess.connect(20000)

                reportLog("SSH Terotentikasi! Server Banner: ${sess.serverVersion}")
                session = sess

                // Local SOCKS5 bridge handles one CONNECT per SSH direct-tcpip
                // channel. UDP is intentionally unsupported in TCP-only mode;
                // HEV MapDNS keeps domain lookups on the CONNECT path.
                startSocks5Server(sess)
                reportLog("SOCKS5 TCP-only siap pada 127.0.0.1:$LOCAL_SOCKS_PORT")
                reportConnected()

                // Keep session alive
                while (isRunning.get() && sess.isConnected) {
                    Thread.sleep(2000)
                }

                if (isRunning.get() && !sess.isConnected) {
                    reportError("Koneksi SSH terputus.")
                }

            } catch (t: Throwable) {
                Log.e(TAG, "SSH Connection error", t)
                val msg = t.message ?: t.javaClass.simpleName
                reportLog("SSH Error: $msg")
                reportError("Gagal konek SSH: $msg")
            } finally {
                try { socksServer?.close() } catch (_: Throwable) {}
                try { session?.disconnect() } catch (_: Throwable) {}
                session = null
                isRunning.set(false)
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

            if (cmd == 3) {
                handleDnsUdpAssociate(client, dos, sshSession)
                return
            }
            if (cmd != 1) {
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
            val clientIn = BufferedInputStream(client.getInputStream(), 64 * 1024)
            val clientOut = BufferedOutputStream(client.getOutputStream(), 64 * 1024)
            val sshIn = BufferedInputStream(ch.inputStream, 64 * 1024)
            val sshOut = BufferedOutputStream(ch.outputStream, 64 * 1024)

            val t1 = Thread {
                try {
                    val buf = ByteArray(32 * 1024)
                    while (isRunning.get()) {
                        val len = clientIn.read(buf)
                        if (len == -1) break
                        sshOut.write(buf, 0, len)
                    }
                    sshOut.flush()
                } catch (_: Exception) {}
            }

            val t2 = Thread {
                try {
                    val buf = ByteArray(32 * 1024)
                    while (isRunning.get()) {
                        val len = sshIn.read(buf)
                        if (len == -1) break
                        clientOut.write(buf, 0, len)
                    }
                    clientOut.flush()
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

    /** DNS-only SOCKS UDP ASSOCIATE: the DNS payload is sent over SSH DNS-over-TCP. */
    private fun handleDnsUdpAssociate(control: Socket, out: DataOutputStream, sshSession: Session) {
        val relay = DatagramSocket(InetSocketAddress("127.0.0.1", 0))
        val relayPort = relay.localPort
        out.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, (relayPort ushr 8).toByte(), relayPort.toByte()))
        out.flush()
        try {
            val buffer = ByteArray(65535)
            while (isRunning.get() && !control.isClosed && !relay.isClosed) {
                val packet = DatagramPacket(buffer, buffer.size)
                relay.receive(packet)
                val length = packet.length
                if (length < 10 || buffer[2].toInt() != 0) continue
                var index = 4
                val atyp = buffer[3].toInt() and 0xff
                val host: String
                when (atyp) {
                    1 -> {
                        if (index + 4 > length) continue
                        host = "${buffer[index].toInt() and 0xff}.${buffer[index + 1].toInt() and 0xff}." +
                            "${buffer[index + 2].toInt() and 0xff}.${buffer[index + 3].toInt() and 0xff}"
                        index += 4
                    }
                    3 -> {
                        val hostLength = buffer[index].toInt() and 0xff
                        index++
                        if (hostLength <= 0 || index + hostLength > length) continue
                        host = String(buffer, index, hostLength, Charsets.US_ASCII)
                        index += hostLength
                    }
                    else -> continue
                }
                if (index + 2 > length) continue
                val destinationPort = ((buffer[index].toInt() and 0xff) shl 8) or (buffer[index + 1].toInt() and 0xff)
                index += 2
                if (destinationPort != 53 || index > length) continue
                // MapDNS uses a synthetic resolver address; resolve through a public DNS server remotely.
                val upstreamDns = if (host == "198.18.0.2") "1.1.1.1" else host
                val response = dnsOverSshTcp(sshSession, upstreamDns, buffer.copyOfRange(index, length)) ?: continue
                val header = buffer.copyOfRange(0, index)
                val reply = ByteArray(header.size + response.size)
                System.arraycopy(header, 0, reply, 0, header.size)
                System.arraycopy(response, 0, reply, header.size, response.size)
                relay.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
            }
        } finally {
            try { relay.close() } catch (_: Throwable) {}
            try { control.close() } catch (_: Throwable) {}
        }
    }

    private fun dnsOverSshTcp(sshSession: Session, dnsHost: String, query: ByteArray): ByteArray? {
        var channel: ChannelDirectTCPIP? = null
        return try {
            if (!sshSession.isConnected || query.isEmpty() || query.size > 65535) return null
            channel = sshSession.openChannel("direct-tcpip") as ChannelDirectTCPIP
            channel.setHost(dnsHost)
            channel.setPort(53)
            channel.connect(8000)
            val output = DataOutputStream(channel.outputStream)
            val input = DataInputStream(channel.inputStream)
            output.writeShort(query.size)
            output.write(query)
            output.flush()
            val responseLength = input.readUnsignedShort()
            if (responseLength <= 0) return null
            ByteArray(responseLength).also { input.readFully(it) }
        } catch (_: Throwable) {
            null
        } finally {
            try { channel?.disconnect() } catch (_: Throwable) {}
        }
    }

    /** Runs separate data-plane probes so the first failing layer is visible. */
    fun probeInternet(timeoutMs: Int = 10000): Boolean {
        if (!isRunning.get()) {
            reportLog("Internet probe: SSH worker belum running")
            return false
        }
        val literal = probeSocksTarget("1.1.1.1", 80, "one.one.one.one", timeoutMs)
        if (!literal) {
            // Do not run the domain probe after a literal-IP failure: otherwise its
            // error would overwrite the first and most useful failure layer.
            return false
        }
        val domain = probeSocksTarget("example.com", 80, "example.com", timeoutMs)
        if (domain) {
            reportLog("Internet probe berhasil: literal IP dan domain menerima respons")
            return true
        }
        lastProbeFailure = "Probe domain gagal setelah TCP literal berhasil; periksa DNS/domain"
        reportLog(lastProbeFailure)
        return false
    }

    private fun probeSocksTarget(target: String, port: Int, httpHost: String, timeoutMs: Int): Boolean {
        return try {
            Socket().use { client ->
                // The probe must bypass the VPN or Android can route it back into TUN.
                // This socket only connects to the app's own loopback SOCKS listener.
                // Some Android 8/9 builds return false for protect() on loopback even
                // though the VPN and local listener are healthy. The SSH transport
                // socket above remains strictly protected; do not fail this local
                // diagnostic before it reaches the SOCKS handshake.
                val protected = vpnService.protect(client)
                if (!protected) {
                    reportLog("Probe $target: protect(loopback)=false; lanjutkan uji SOCKS lokal")
                }
                client.soTimeout = timeoutMs
                client.connect(InetSocketAddress("127.0.0.1", LOCAL_SOCKS_PORT), timeoutMs)
                val input = DataInputStream(client.getInputStream())
                val output = DataOutputStream(client.getOutputStream())
                output.write(byteArrayOf(5, 1, 0))
                output.flush()
                val version = input.readUnsignedByte()
                val method = input.readUnsignedByte()
                if (version != 5 || method != 0) {
                    return probeFailure("Probe $target: SOCKS handshake gagal (v=$version method=$method)")
                }
                val ipv4 = target.split('.').takeIf { it.size == 4 }?.mapNotNull { it.toIntOrNull() }
                    ?.takeIf { it.size == 4 && it.all { octet -> octet in 0..255 } }
                output.writeByte(5)
                output.writeByte(1)
                output.writeByte(0)
                if (ipv4 != null) {
                    // Send a true IPv4 SOCKS request; this avoids a DNS lookup on the probe path.
                    output.writeByte(1)
                    ipv4.forEach { output.writeByte(it) }
                } else {
                    val hostBytes = target.toByteArray(Charsets.US_ASCII)
                    output.writeByte(3)
                    output.writeByte(hostBytes.size)
                    output.write(hostBytes)
                }
                output.writeShort(port)
                output.flush()
                // SOCKS5 reply: VER, REP, RSV, ATYP, BND.ADDR, BND.PORT.
                // RSV is one byte; ATYP must be read exactly once.
                val responseVersion = input.readUnsignedByte()
                val reply = input.readUnsignedByte()
                input.readUnsignedByte() // RSV
                val atyp = input.readUnsignedByte()
                when (atyp) {
                    1 -> repeat(4) { input.readUnsignedByte() }
                    3 -> repeat(input.readUnsignedByte()) { input.readUnsignedByte() }
                    4 -> repeat(16) { input.readUnsignedByte() }
                    else -> {
                        return probeFailure("Probe $target: SOCKS reply address type tidak valid ($atyp)")
                    }
                }
                input.readUnsignedShort()
                if (responseVersion != 5 || reply != 0) {
                    return probeFailure("Probe $target: SOCKS CONNECT ditolak (reply=$reply)")
                }
                output.write("HEAD / HTTP/1.1\\r\\nHost: $httpHost\\r\\nConnection: close\\r\\n\\r\\n".toByteArray(Charsets.US_ASCII))
                output.flush()
                val first = input.read()
                if (first < 0) {
                    return probeFailure("Probe $target: CONNECT sukses tetapi downstream kosong")
                }
                reportLog("Probe $target: downstream byte diterima")
                true
            }
        } catch (t: Throwable) {
            probeFailure("Probe $target gagal: ${t.message ?: t.javaClass.simpleName}")
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
