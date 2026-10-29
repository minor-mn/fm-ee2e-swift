enum ConflictChoice { case overwrite, rename, skip }

struct ConflictDecision {
  init(_ choice: ConflictChoice, applyToAll: Bool = false) {
    self.choice = choice
    self.applyToAll = applyToAll
  }

  let choice: ConflictChoice
  let applyToAll: Bool
}

/// 同名ファイルについて利用者に尋ねる。nil は転送全体の中止。
typealias ConflictResolver = (String) async -> ConflictDecision?

struct PlanCancelled: Error {}

/// 同名の確認。「すべてに適用」を選んだら以降は聞かない。
final class Conflicts {
  init(_ resolver: @escaping ConflictResolver) {
    self.resolver = resolver
  }

  let resolver: ConflictResolver
  private var all: ConflictChoice?

  func ask(_ path: String) async throws -> ConflictChoice {
    if let remembered = all {
      return remembered
    }
    guard let decision = await resolver(path) else {
      throw PlanCancelled()
    }
    if decision.applyToAll {
      all = decision.choice
    }
    return decision.choice
  }
}
