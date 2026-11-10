import Testing

@testable import FmEe2eCore

struct ContainerRunArgsTests {
  @Test("保存した create から、使い捨てのコンテナの container run を組む")
  func runArgs() {
    let definition = NativeContainerDefinition(
      service: "app", name: "app", image: "career-app:latest",
      create: [
        "create", "--name", "app", "--label", "fm-ee2e.compose.project=career", "--memory", "4G",
        "--platform", "linux/amd64", "--rosetta", "--tty", "--interactive", "--env", "SSL=true",
        "--publish", "3000:3000", "--volume", "/work/career:/app", "--volume", "career-app-gems:/usr/local/bundle",
        "--network", "career-default,alias=app.career.container,alias=careerindex.local.jp",
        "career-app:latest", "/bin/bash", "-lc", "exec rails s",
      ],
      prepare: [], problem: nil)
    #expect(
      definition.runArgs("bundle install") == [
        "run", "--rm", "--memory", "4G", "--platform", "linux/amd64", "--rosetta", "--tty", "--interactive", "--env", "SSL=true",
        "--volume", "/work/career:/app", "--volume", "career-app-gems:/usr/local/bundle", "--network", "career-default",
        "career-app:latest", "/bin/sh", "-c", "bundle install",
      ])
  }

  @Test("-it がなければ足す")
  func addsInteractive() {
    let definition = NativeContainerDefinition(
      service: "web", name: "web", image: "busybox", create: ["create", "--name", "web", "busybox"], prepare: [], problem: nil)
    #expect(definition.runArgs("ls") == ["run", "--rm", "--interactive", "--tty", "busybox", "/bin/sh", "-c", "ls"])
  }
}
