import Foundation

/// Unix domain socket 地址的构造与调用封装
///
/// 主程序与特权助手都需要把路径填进 sockaddr_un 的定长 sun_path 字段，
/// 这段转换放在共享文件里，避免两侧各写一份。
enum UnixSocket {

    /// 构造并填充 Unix socket 地址
    /// - Parameter path: socket 文件路径
    /// - Returns: 填好的地址；路径超出 sun_path 容量时返回 nil
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // strlcpy 需要给结尾的 \0 留一个位置
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }
        return address
    }

    /// 以 sockaddr 指针的形式执行一段调用
    /// - Parameters:
    ///   - address: 待转换的地址
    ///   - body: 接收指针与长度的闭包，通常直接调用 bind / connect
    /// - Returns: body 的返回值
    static func withSockaddr<T>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
