// Claude Usage/Shared/Models/RaceEntry.swift
import Foundation

/// A single race the client has joined.
/// Stored as a JSON-encoded list in UserDefaults.
struct RaceEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let url: String       // full race URL including slug
    var name: String?     // display name cached from server on first poll

    init(id: UUID = UUID(), url: String, name: String? = nil) {
        self.id = id
        self.url = url
        self.name = name
    }
}
