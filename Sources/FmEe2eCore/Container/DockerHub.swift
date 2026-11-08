import Foundation

/// Docker Hub の公開 API でイメージを探す（docker search と同じもの）。
enum DockerHub {
  struct Repository: Decodable {
    let repoName: String
    let shortDescription: String?
    let starCount: Int?
    let isOfficial: Bool?

    enum CodingKeys: String, CodingKey {
      case repoName = "repo_name", shortDescription = "short_description", starCount = "star_count", isOfficial = "is_official"
    }
  }

  struct Tag: Decodable {
    struct Image: Decodable {
      let architecture: String?
    }
    let name: String
    let lastUpdated: String?
    let images: [Image]?

    enum CodingKeys: String, CodingKey { case name, lastUpdated = "last_updated", images }

    var architectures: Set<String> { Set((images ?? []).compactMap(\.architecture)) }
  }

  private struct Page<T: Decodable>: Decodable { let results: [T] }

  private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> [T] {
    var components = URLComponents(string: "https://hub.docker.com/v2/" + path)!
    components.queryItems = query
    let (data, response) = try await URLSession.shared.data(from: components.url!)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      throw AppError(tr("container.images.hub_failed", ["status": "\(http.statusCode)"]))
    }
    return try JSONDecoder().decode(Page<T>.self, from: data).results
  }

  /// [query] に合うイメージ。公式イメージを先に、あとは Docker Hub の順のまま。
  static func search(_ query: String) async throws -> [Repository] {
    let found: [Repository] = try await get("search/repositories/", [URLQueryItem(name: "query", value: query), URLQueryItem(name: "page_size", value: "50")])
    return found.filter { $0.isOfficial == true } + found.filter { $0.isOfficial != true }
  }

  /// [repository] のタグのうち、[architecture] のイメージがあるもの。新しく更新された順。[name] を入れれば、その文字を含むものに絞る。
  static func tags(_ repository: String, name: String, architecture: String) async throws -> [Tag] {
    let path = repository.contains("/") ? repository : "library/\(repository)"
    var query = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "ordering", value: "last_updated")]
    if !name.isEmpty { query.append(URLQueryItem(name: "name", value: name)) }
    let found: [Tag] = try await get("repositories/\(path)/tags", query)
    return found.filter { $0.architectures.contains(architecture) }
  }
}
