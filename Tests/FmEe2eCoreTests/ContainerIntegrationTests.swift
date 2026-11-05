import Foundation
import Testing

@testable import FmEe2eCore

/// 明示的に有効にしたときだけ、専用のコンテナ・ネットワーク・ボリュームを作って片付ける。
@MainActor
struct ContainerIntegrationTests {
  @Test("外部プロジェクトの compose を実行せず変換する", .enabled(if: ProcessInfo.processInfo.environment["FM_EE2E_COMPOSE_TEST_DIR"] != nil))
  func externalCompose() throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = try #require(environment["FM_EE2E_COMPOSE_TEST_DIR"])
    let service = environment["FM_EE2E_COMPOSE_TEST_SERVICE"] ?? "app"
    let project = try ComposeProject.load(ComposeProject.discover(directory))
    let externalVolumes = Set(project.volumes.map { key, value in
      (value as? [String: Any])?["name"] as? String ?? key
    })
    let plan = try project.plan(service, volumes: externalVolumes)
    #expect(plan.create.starts(with: ["create", "--name", project.containerName(service)]))
  }

  @Test("Container の起動停止・DNS・ファイル操作・tar 往復転送", .enabled(if: ProcessInfo.processInfo.environment["FM_EE2E_CONTAINER_TESTS"] == "1"))
  func roundTrip() async throws {
    let client = ContainerClient()
    #expect(try await client.systemRunning())
    let id = "fm-test-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(id).path
    try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: temp) }
    let compose = p.join(temp, "compose.yaml")
    try """
      name: \(id)
      services:
        server:
          container_name: \(id)-server
          image: busybox:1.37.0
          platform: linux/x86_64
          command: [sleep, '300']
          volumes: ['data:/var/spool/mail']
        client:
          container_name: \(id)-client
          image: busybox:1.37.0
          command: ['sh', '-c', 'nslookup server.\(id).container >/dev/null && exec sleep 300']
          depends_on: [server]
      volumes: {data: null}
      """.write(toFile: compose, atomically: true, encoding: .utf8)
    let project = try ComposeProject.load([compose], environment: [:])
    func cleanup() async {
      for service in ["client", "server"] { _ = try? await client.execute(["delete", "--force", project.containerName(service)]) }
      _ = try? await client.execute(["network", "delete", "\(id)-default"])
      _ = try? await client.execute(["volume", "delete", "\(id)-data"])
    }
    do {
      // 保存する設定と同じ形に変換し、依存先から順に作って起動する。
      let native = try NativeContainerProject.importDraft(project)
      for service in ["server", "client"] {
        let definition = try #require(native.definitions.first { $0.service == service })
        for step in try await native.createSteps(definition, client: client) { try await client.checked(step, in: native.root) }
        try await client.checked(["start", definition.name])
      }
      let containers = try await client.list()
      #expect(containers.contains { $0.name == project.containerName("client") && $0.running })
      let remote = ContainerConnection(project.containerName("client"), client: client)
      // 新しいボリュームは lost+found を除き、イメージのマウント先の持ち主（busybox の mail は 8:8）を引き継ぐ。
      let volume = try await ContainerConnection(project.containerName("server"), client: client).exec("stat -c %u:%g /var/spool/mail && ! test -e /var/spool/mail/lost+found")
      #expect(volume.exitCode == 0 && volume.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "8:8", "\(volume.stdout)\(volume.stderr)")
      let canonical = project.containerName("server") + ".container"
      for name in [canonical, "server.\(id).container"] {
        let hostDns = try await runProcess("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", name])
        #expect(hostDns.exitCode == 0 && hostDns.stdout.contains("ip_address:"), "\(hostDns.stdout)\(hostDns.stderr)")
      }
      // 短いサービス名は検索ドメインで <サービス名>.<プロジェクト名>.container として引く。
      let dns = try await remote.exec("nslookup \(canonical) && nslookup server.\(id).container && ping -c 1 -W 2 server")
      #expect(dns.exitCode == 0, "\(dns.stderr)\(dns.stdout)")
      let source = p.join(temp, "日本語 ' $x")
      try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
      let data = Data(repeating: 0x7b, count: 4 * 1024 * 1024)
      try data.write(to: URL(fileURLWithPath: p.join(source, "data ' $x.bin")))
      try FileManager.default.createSymbolicLink(atPath: p.join(source, "link"), withDestinationPath: "data ' $x.bin")
      let staging = try await remote.transferTemp("/tmp")
      let uploaded = PathContext.posix.join(staging, "payload")
      let upload = try await remote.copyTar(source, uploaded, upload: true)
      #expect(upload.exitCode == 0, "\(upload.stderr)")
      let entries = try await remote.list(uploaded)
      #expect(entries.contains { $0.name == "link" && $0.isLink })
      #expect(entries.contains { $0.name == "data ' $x.bin" && $0.size == data.count })
      let downloadDir = p.join(temp, "download")
      try FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
      let downloaded = p.join(downloadDir, "payload")
      let download = try await remote.copyTar(uploaded, downloaded, upload: false)
      #expect(download.exitCode == 0, "\(download.stderr)")
      #expect(try Data(contentsOf: URL(fileURLWithPath: p.join(downloaded, "data ' $x.bin"))) == data)
      #expect(try FileManager.default.destinationOfSymbolicLink(atPath: p.join(downloaded, "link")) == "data ' $x.bin")
      let streamed = p.join(temp, "streamed.bin")
      try await remote.download(PathContext.posix.join(uploaded, "data ' $x.bin"), to: streamed)
      #expect(try Data(contentsOf: URL(fileURLWithPath: streamed)) == data)
      let folder = PathContext.posix.join(staging, "folder")
      try await remote.mkdir(folder)
      try await remote.touch(folder + "/file")
      try await remote.move(folder + "/file", folder + "/renamed")
      try await remote.chmod(0o600, folder + "/renamed")
      #expect(try await remote.list(folder).first?.mode == 0o600)
      try await remote.remove([folder])
      #expect(try await !remote.exists(folder))
      for service in ["client", "server"] { try await client.checked(["stop", project.containerName(service)]) }
      let stopped = try await client.list()
      #expect(stopped.filter { $0.name.hasPrefix(id) }.allSatisfy { !$0.running })
      for service in ["server", "client"] { try await client.checked(["start", project.containerName(service)]) }
      let afterRestart = try await remote.exec("nslookup \(canonical) && ping -c 1 -W 2 server")
      #expect(afterRestart.exitCode == 0, "\(afterRestart.stdout)\(afterRestart.stderr)")
      await cleanup()
    } catch {
      await cleanup()
      throw error
    }
  }
}
