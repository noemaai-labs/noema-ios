import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        // The visionOS target currently uses Core Data infrastructure without relying on a concrete
        // managed object subclass. Keep the preview initializer lightweight to avoid referencing
        // generated Core Data types that may not be available when building previews.
        PersistenceController(inMemory: true)
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Noema")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores(completionHandler: { (_, error) in
            if let error = error as NSError? {
                // Core Data is not the source of truth for Noema's app state. Keep the
                // process alive if this optional store is unavailable or cannot migrate.
                NSLog("[Persistence] Failed to load Core Data store: %@", error)
            }
        })
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
