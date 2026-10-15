import Combine
import Foundation

/// Shared by all client instances, including history and legacy file actions.
/// A hidden window does not make an in-flight package operation disappear.
@MainActor final class GaoActionActivity:ObservableObject {
    static let shared=GaoActionActivity()
    @Published private(set) var operations:Set<UUID>=[]
    var isBusy:Bool {!operations.isEmpty}
    func begin()->UUID {let token=UUID();operations.insert(token);return token}
    func end(_ token:UUID) {operations.remove(token)}
}
