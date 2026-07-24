import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Read tool

public struct CalendarEventsTool: Tool {
    public let name = "noema.calendar.events"
    public let description = "Read the user's calendar events within a date range (read-only). Use to answer questions like \"what's on my calendar tomorrow\" or \"am I free Friday afternoon\". Returns events with title, start, end, location, and calendar."
    public let schema = #"""
    { "type":"object", "properties":{
        "start_date":{"type":"string","description":"Start of the range, ISO 8601 (e.g. 2026-06-29T00:00:00Z or 2026-06-29)."},
        "end_date":{"type":"string","description":"End of the range, ISO 8601."},
        "max_results":{"type":"integer","minimum":1,"maximum":100,"default":50,"description":"Maximum number of events to return."}
    }, "required":["start_date","end_date"] }
    """#

    public init() {}

    public func call(args: Data) async throws -> Data {
        struct Args: Decodable { let start_date: String; let end_date: String; let max_results: Int? }
        let input = try JSONDecoder().decode(Args.self, from: args)
        #if canImport(EventKit)
        guard let start = CalendarSupport.parseDate(input.start_date),
              let end = CalendarSupport.parseDate(input.end_date), end >= start else {
            return try CalendarSupport.errorData("Provide valid ISO 8601 start_date and end_date, with end on or after start.")
        }
        let limit = max(1, min(input.max_results ?? 50, 100))
        guard await CalendarSupport.ensureAccess() else {
            return try CalendarSupport.errorData("Calendar access wasn't granted. The user can enable it in Settings › Privacy › Calendars.")
        }
        let events = await CalendarSupport.fetchEvents(start: start, end: end, limit: limit)
        return try JSONEncoder().encode(CalendarSupport.EventsResult(events: events))
        #else
        return try CalendarSupport.errorData("Calendar isn't available on this platform.")
        #endif
    }
}

// MARK: - Write tool (confirm before commit)

public struct CalendarAddEventTool: Tool {
    public let name = "noema.calendar.addEvent"
    public let description = "Create a calendar event. The user is shown a confirmation with the event details and must approve before anything is saved — never assume it was created. Use after the user asks to schedule something."
    public let schema = #"""
    { "type":"object", "properties":{
        "title":{"type":"string","description":"Event title."},
        "start_date":{"type":"string","description":"Start, ISO 8601."},
        "end_date":{"type":"string","description":"End, ISO 8601."},
        "location":{"type":"string","description":"Optional location."},
        "notes":{"type":"string","description":"Optional notes."},
        "all_day":{"type":"boolean","default":false,"description":"Whether this is an all-day event."}
    }, "required":["title","start_date","end_date"] }
    """#

    public init() {}

    public func call(args: Data) async throws -> Data {
        struct Args: Decodable {
            let title: String; let start_date: String; let end_date: String
            let location: String?; let notes: String?; let all_day: Bool?
        }
        let input = try JSONDecoder().decode(Args.self, from: args)
        #if canImport(EventKit)
        if ToolDryRunSupport.isEnabled {
            return Data(ToolDryRunSupport.resultString(toolName: name, arguments: [
                "title": input.title, "start_date": input.start_date, "end_date": input.end_date
            ]).utf8)
        }
        guard let start = CalendarSupport.parseDate(input.start_date),
              let end = CalendarSupport.parseDate(input.end_date), end >= start else {
            return try CalendarSupport.errorData("Provide valid ISO 8601 start_date and end_date, with end on or after start.")
        }
        guard await CalendarSupport.ensureAccess(allowWriteOnly: true) else {
            return try CalendarSupport.errorData("Calendar access wasn't granted.")
        }
        // Cap the free-text fields so a runaway model can't balloon the confirmation
        // sheet or the saved event.
        let pending = CalendarConfirmationStore.PendingEvent(
            title: String(input.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            start: start, end: end,
            location: input.location.map { String($0.prefix(500)) },
            notes: input.notes.map { String($0.prefix(2000)) },
            allDay: input.all_day ?? false
        )
        let approved = await CalendarConfirmationStore.shared.requestConfirmation(pending)
        guard approved else {
            return try JSONEncoder().encode(CalendarSupport.SaveResult(ok: false, event_id: nil, error: "user_declined"))
        }
        let result = await CalendarSupport.saveEvent(pending)
        return try JSONEncoder().encode(result)
        #else
        return try CalendarSupport.errorData("Calendar isn't available on this platform.")
        #endif
    }
}

// MARK: - Shared support

enum CalendarSupport {
    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = df.date(from: trimmed) { return d }
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: trimmed)
    }

    static func errorData(_ message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": false, "error": message])
    }

    struct CalendarEvent: Codable, Sendable {
        let title: String; let start: String; let end: String
        let location: String?; let notes: String?; let calendar: String?; let all_day: Bool
    }
    struct EventsResult: Codable, Sendable { let events: [CalendarEvent] }
    struct SaveResult: Codable, Sendable { let ok: Bool; let event_id: String?; let error: String? }

    #if canImport(EventKit)
    @MainActor static let store = EKEventStore()

    @MainActor
    static func ensureAccess(allowWriteOnly: Bool = false) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return true }
        // iOS's "Add Events Only" grant is enough to save an event, just not to read.
        if allowWriteOnly, status == .writeOnly { return true }
        if status == .notDetermined {
            if (try? await store.requestFullAccessToEvents()) ?? false { return true }
            if allowWriteOnly {
                return EKEventStore.authorizationStatus(for: .event) == .writeOnly
            }
        }
        return false
    }

    @MainActor
    static func fetchEvents(start: Date, end: Date, limit: Int) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let iso = ISO8601DateFormatter()
        return store.events(matching: predicate).prefix(limit).map { event in
            CalendarEvent(
                title: event.title ?? String(localized: "(no title)"),
                start: iso.string(from: event.startDate),
                end: iso.string(from: event.endDate),
                location: event.location,
                notes: event.notes,
                calendar: event.calendar?.title,
                all_day: event.isAllDay
            )
        }
    }

    @MainActor
    static func saveEvent(_ pending: CalendarConfirmationStore.PendingEvent) -> SaveResult {
        let event = EKEvent(eventStore: store)
        event.title = pending.title
        event.startDate = pending.start
        event.endDate = pending.end
        event.isAllDay = pending.allDay
        if let location = pending.location, !location.isEmpty { event.location = location }
        if let notes = pending.notes, !notes.isEmpty { event.notes = notes }
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return SaveResult(ok: true, event_id: event.eventIdentifier, error: nil)
        } catch {
            return SaveResult(ok: false, event_id: nil, error: error.localizedDescription)
        }
    }
    #else
    @MainActor static func ensureAccess() async -> Bool { false }
    #endif
}

// MARK: - Confirmation store + host

@MainActor
final class CalendarConfirmationStore: ObservableObject {
    static let shared = CalendarConfirmationStore()

    struct PendingEvent: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let start: Date
        let end: Date
        let location: String?
        let notes: String?
        let allDay: Bool
    }

    @Published var pending: PendingEvent?
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestConfirmation(_ event: PendingEvent) async -> Bool {
        // Only one confirmation at a time; decline a second concurrent request.
        if continuation != nil { return false }
        // If the chat is stopped (or the app tears the stream down) while the sheet is
        // pending, the continuation must be resumed anyway: a parked continuation would
        // leak the stream task AND leave `continuation != nil`, permanently declining
        // every future addEvent until relaunch.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                continuation = cont
                pending = event
            }
        } onCancel: {
            Task { @MainActor in
                CalendarConfirmationStore.shared.resolveIfPending(false)
            }
        }
    }

    func resolve(_ approved: Bool) {
        let cont = continuation
        continuation = nil
        pending = nil
        cont?.resume(returning: approved)
    }

    /// Resolve as declined only if a request is still in flight (e.g. swipe-dismiss).
    func resolveIfPending(_ approved: Bool) {
        guard continuation != nil else { return }
        resolve(approved)
    }
}

#if canImport(SwiftUI)
struct CalendarConfirmationHost: ViewModifier {
    @ObservedObject private var store = CalendarConfirmationStore.shared

    func body(content: Content) -> some View {
        content.sheet(item: $store.pending) { event in
            CalendarConfirmationSheet(
                event: event,
                onApprove: { store.resolve(true) },
                onCancel: { store.resolve(false) }
            )
            .onDisappear { store.resolveIfPending(false) }
#if os(iOS) || os(visionOS)
            .interactiveDismissDisabled(true)
#endif
        }
    }
}

extension View {
    /// Hosts the calendar create-event confirmation sheet. Apply once near an app root.
    func calendarConfirmationHost() -> some View { modifier(CalendarConfirmationHost()) }
}

private struct CalendarConfirmationSheet: View {
    let event: CalendarConfirmationStore.PendingEvent
    let onApprove: () -> Void
    let onCancel: () -> Void

    private var dateRange: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = event.allDay ? .none : .short
        if event.allDay {
            return df.string(from: event.start)
        }
        return "\(df.string(from: event.start)) – \(df.string(from: event.end))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.red)
                Text(LocalizedStringKey("Add to Calendar?"))
                    .font(.title3.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(event.title.isEmpty ? String(localized: "(no title)") : event.title)
                    .font(.headline)
                Label(dateRange, systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))

            HStack(spacing: 12) {
                Button(role: .cancel) { onCancel() } label: {
                    Text(LocalizedStringKey("Cancel")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { onApprove() } label: {
                    Text(LocalizedStringKey("Add Event")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
#if os(macOS)
        .frame(width: 380)
#else
        .presentationDetents([.medium])
#endif
    }
}
#endif
