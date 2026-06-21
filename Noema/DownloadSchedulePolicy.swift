import Foundation

struct DownloadSchedulePolicy: Equatable {
    struct Environment: Equatable {
        var date: Date
        var calendar: Calendar
        var isCharging: Bool
        var isOnWiFi: Bool
    }

    static let overnightStartHour = 22
    static let overnightEndHour = 7

    static func canResumeScheduledDownloads(in environment: Environment) -> Bool {
        isOvernight(environment.date, calendar: environment.calendar) &&
        environment.isCharging &&
        environment.isOnWiFi
    }

    static func isOvernight(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= overnightStartHour || hour < overnightEndHour
    }
}
