import Foundation
import CryptoKit

actor AttachmentFiles {
    let root: URL
    let configuration: Configuration
    init(directory: URL, configuration: Configuration) {
        root = directory.appendingPathComponent("attachments", isDirectory: true)
        self.configuration = configuration
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "SongNote.Attachments", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func boundedData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: 65536), !part.isEmpty {
            guard data.count + part.count <= Attachment.maxBytes else { throw failure("单个附件不能超过 20 MiB。") }
            data.append(part)
        }
        return data
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func cache(_ data: Data, hash: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent(hash)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
    func importFile(_ source: URL) throws -> Attachment {
        let data = try Self.boundedData(source)
        let value = Attachment(id: UUID().uuidString, name: source.lastPathComponent, size: data.count, sha256: Self.hash(data))
        guard value.valid else { throw Self.failure("附件名称或信息无效。") }
        _ = try cache(data, hash: value.sha256)
        return value
    }
    func request(_ method: String, _ endpoint: String) throws -> URLRequest {
        guard let url = URL(string: configuration.base_url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + endpoint) else {
            throw Self.failure("同步配置无效。")
        }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 120
        request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        return request
    }
    func checkSupport() async throws {
        let (data, response) = try await URLSession.shared.data(for: request("GET", "/health"))
        struct Health: Decodable { var features: [String]? }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data), health.features?.contains("attachments") == true else {
            throw Self.failure("服务器尚未支持附件，文件保留在本机待传。")
        }
    }
    func upload(_ value: Attachment) async throws {
        guard value.valid else { throw Self.failure("附件信息无效。") }
        let (_, head) = try await URLSession.shared.data(for: request("HEAD", "/v1/files/" + value.sha256))
        let status = (head as? HTTPURLResponse)?.statusCode
        if status == 200 && head.expectedContentLength == Int64(value.size) { return }
        guard status == 404 else { throw Self.failure("附件查询失败，请重试。") }
        let path = root.appendingPathComponent(value.sha256)
        let data = try Self.boundedData(path)
        guard data.count == value.size, Self.hash(data) == value.sha256 else { throw Self.failure("本机附件缺失或损坏，文件保留待重试。") }
        var put = try request("PUT", "/v1/files/" + value.sha256)
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: put, fromFile: path)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Self.failure("附件上传失败，文件已保留待重试。") }
    }
    func download(_ value: Attachment, to destination: URL) async throws {
        guard value.valid else { throw Self.failure("附件信息无效。") }
        var path = root.appendingPathComponent(value.sha256)
        let existing = try? Self.boundedData(path)
        if existing?.count != value.size || existing.map({ Self.hash($0) }) != value.sha256 {
            let (temporary, response) = try await URLSession.shared.download(for: request("GET", "/v1/files/" + value.sha256))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength == Int64(value.size) else {
                throw Self.failure("附件下载失败或大小不匹配。")
            }
            let data = try Self.boundedData(temporary)
            guard data.count == value.size, Self.hash(data) == value.sha256 else { throw Self.failure("附件完整性校验失败，请重试。") }
            path = try cache(data, hash: value.sha256)
        }
        try Self.boundedData(path).write(to: destination, options: .atomic)
    }
}
