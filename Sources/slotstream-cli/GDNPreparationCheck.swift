import ArgumentParser
import Slotstream

struct GDNPreparationCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gdn-preparation-check")
    @OptionGroup var model: ModelOptions
    func run() throws {
        if try !GDNPreparationProbe.run(modelURL: model.modelURL) { throw ExitCode(2) }
    }
}
