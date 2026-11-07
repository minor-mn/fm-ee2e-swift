import Testing

@testable import FmEe2eCore

/// コンテナ一覧の Dockerfile・Containerfile の行。
@MainActor
struct DockerfileTargetTests {
  @Test func detectsDockerfileAndContainerfile() {
    for name in ["Dockerfile", "Dockerfile.dev", "api.Dockerfile", "Containerfile", "Containerfile.dev", "api.containerfile"] {
      #expect(DockerfileTarget.isDockerfile(name), "\(name)")
    }
    for name in ["Dockerfile-old", "README.md", "containerfiles"] {
      #expect(!DockerfileTarget.isDockerfile(name), "\(name)")
    }
  }

  @Test func namesImageFromFolderAndSuffix() {
    #expect(DockerfileTarget.imageName("/x/door/Dockerfile") == "door:latest")
    #expect(DockerfileTarget.imageName("/x/door/Dockerfile.dev") == "door-dev:latest")
    #expect(DockerfileTarget.imageName("/x/door/api.Dockerfile") == "door-api:latest")
    #expect(DockerfileTarget.imageName("/x/door/Containerfile") == "door:latest")
    #expect(DockerfileTarget.imageName("/x/door/Containerfile.dev") == "door-dev:latest")
    #expect(DockerfileTarget.imageName("/x/door/api.Containerfile") == "door-api:latest")
  }

  @Test func containerfileGoesToItsOwnBlock() {
    #expect(DockerfileTarget(path: "/x/Containerfile.dev", image: "x", built: false).isContainerfile)
    #expect(!DockerfileTarget(path: "/x/Dockerfile", image: "x", built: false).isContainerfile)
  }
}
