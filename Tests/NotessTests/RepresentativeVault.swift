import Foundation
import NotessCore

/// Writes a reproducible, representative Vault for the global search latency
/// measurement (#83): Daily Entries over many years, Free Notes in folders and
/// Brain Notes, Czech text with diacritics, Tags (including a longer Tag that
/// shares a prefix) and notes with several matching Sections. The same seed
/// always writes the same files.
struct RepresentativeVault {
    struct Counts: Equatable {
        var dailyEntries = 7_000
        var freeNotes = 2_500
        var brainNotes = 500

        var total: Int { dailyEntries + freeNotes + brainNotes }
    }

    /// A rare word, written into every `rareWordEvery`-th note (7 of 10,000).
    static let rareWord = "zřídkavý"
    static let rareWordEvery = 1_429

    let counts: Counts
    let seed: UInt64

    init(counts: Counts = Counts(), seed: UInt64 = 83) {
        self.counts = counts
        self.seed = seed
    }

    var summary: String {
        "\(counts.total) files: \(counts.dailyEntries) Daily Entries, \(counts.freeNotes) Free Notes, "
            + "\(counts.brainNotes) Brain Notes (seed \(seed))"
    }

    /// Writes every note under `root` and returns the number of bytes written.
    @discardableResult
    func write(to root: URL) throws -> Int {
        var random = SplitMix64(seed: seed)
        var bytes = 0
        var createdFolders: Set<String> = []
        var fileNumber = 0

        func store(_ text: String, at relativePath: String) throws {
            let url = root.appending(path: relativePath, directoryHint: .notDirectory)
            let folder = url.deletingLastPathComponent().path(percentEncoded: false)
            if createdFolders.insert(folder).inserted {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            let data = Data(text.utf8)
            try data.write(to: url)
            bytes += data.count
            fileNumber += 1
        }

        func rareSentence() -> String? {
            fileNumber % Self.rareWordEvery == 0 ? "Tohle je \(Self.rareWord) záznam pro měření." : nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let firstDay = calendar.date(from: DateComponents(year: 2007, month: 1, day: 1))!
        for offset in 0..<counts.dailyEntries {
            let date = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let stamp = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            let path = String(format: "Journal/%04d/%02d/%@.md", parts.year!, parts.month!, stamp)
            var text = "# \(stamp)\n\n\(sentence(&random))\n"
            if let rare = rareSentence() { text += rare + "\n" }
            for topic in pick(Self.journalTopics, count: 2 + random.next(4), &random) {
                text += "\n" + section(topic, &random)
            }
            try store(text, at: path)
        }

        for number in 0..<counts.freeNotes {
            let folder = Self.noteFolders[number % Self.noteFolders.count]
            let name = "\(Self.noteNames[number % Self.noteNames.count]) \(number)"
            var text = "# \(name)\n\n\(sentence(&random))\n"
            if let rare = rareSentence() { text += rare + "\n" }
            for topic in pick(Self.noteTopics, count: 2 + random.next(4), &random) {
                text += "\n" + section(topic, &random)
            }
            try store(text, at: folder.isEmpty ? "\(name).md" : "\(folder)/\(name).md")
        }

        for number in 0..<counts.brainNotes {
            let folder = Self.brainFolders[number % Self.brainFolders.count]
            let name = "\(Self.brainNames[number % Self.brainNames.count]) \(number)"
            var text = "# \(name)\n\n"
            if let rare = rareSentence() { text += rare + "\n\n" }
            for topic in pick(Self.brainTopics, count: 2 + random.next(3), &random) {
                text += "## \(topic)\n"
                for _ in 0..<(2 + random.next(4)) {
                    let year = 2007 + random.next(19)
                    let month = 1 + random.next(12)
                    let day = 1 + random.next(28)
                    let source = String(format: "Journal/%04d/%02d/%04d-%02d-%02d", year, month, year, month, day)
                    text += "- \(sentence(&random)) [[\(source)#\(Self.journalTopics[random.next(Self.journalTopics.count)])]]\n"
                }
                text += "\n"
            }
            try store(text, at: "\(NoteKind.brainFolder)/\(folder)/\(name).md")
        }
        return bytes
    }

    private func section(_ topic: String, _ random: inout SplitMix64) -> String {
        var text = "## \(topic)\n"
        for _ in 0..<(1 + random.next(3)) {
            var paragraph = (0..<(2 + random.next(4))).map { _ in sentence(&random) }
            // Several Sections of one note can match the same words.
            if topic.lowercased().contains("kickoff") || random.next(6) == 0 {
                paragraph.append("Navazujeme na kickoff s klientem a rozpočet.")
            }
            if random.next(4) == 0 {
                paragraph.append(Self.tags[random.next(Self.tags.count)])
            }
            text += paragraph.joined(separator: " ") + "\n"
        }
        if random.next(5) == 0 {
            text += "- [ ] \(sentence(&random))\n- [x] \(sentence(&random))\n"
        }
        return text + "\n"
    }

    private func sentence(_ random: inout SplitMix64) -> String {
        let words = (0..<(6 + random.next(12))).map { _ in word(&random) }
        return words.joined(separator: " ").capitalizedFirst + "."
    }

    private func word(_ random: inout SplitMix64) -> String {
        if random.next(3) == 0 {
            return Self.words[random.next(Self.words.count)]
        }
        // A large invented vocabulary, as real notes have, built from syllables.
        return (0..<(2 + random.next(3))).map { _ in Self.syllables[random.next(Self.syllables.count)] }.joined()
    }

    private func pick(_ items: [String], count: Int, _ random: inout SplitMix64) -> [String] {
        var pool = items
        var picked: [String] = []
        for _ in 0..<min(count, pool.count) {
            picked.append(pool.remove(at: random.next(pool.count)))
        }
        return picked
    }

    static let journalTopics = [
        "Porada", "Kickoff s klientem", "Retro", "Telefonát", "Nápady", "Úkoly", "Čtení",
        "Zdraví", "Rodina", "Cesta", "Plánování", "Kickoff týmu",
    ]
    static let noteTopics = ["Cíle", "Kickoff", "Rozpočet", "Rizika", "Lidé", "Poznámky", "Rozhodnutí", "Odkazy"]
    static let brainTopics = ["Fakta", "Lidé", "Projekty", "Historie", "Otevřené otázky"]
    static let noteFolders = ["Projekty", "Lidé", "Archiv/2019", "Archiv/2023", "Oblasti/Práce", "Oblasti/Domov", ""]
    static let noteNames = ["Projekt", "Schůzka", "Návrh", "Shrnutí", "Postup", "Seznam", "Kontakt"]
    static let brainFolders = ["companies", "people", "topics"]
    static let brainNames = ["Firma", "Osoba", "Téma"]
    static let tags = ["#projekt", "#projekty", "#klient", "#zdraví", "#nápad", "#retro", "#acme", "#čtení"]
    static let words = [
        "klient", "rozpočet", "projekt", "smlouva", "schůzka", "termín", "úkol", "plán", "tým", "návrh",
        "faktura", "dodávka", "příprava", "přehled", "řešení", "změna", "žádost", "účet", "výsledek",
        "kvalita", "rychlost", "zpráva", "školení", "údržba", "hodnocení", "obchod", "nákup", "cena",
        "jídlo", "běh", "spánek", "kniha", "článek", "dovolená", "auto", "vlak", "letiště", "počasí",
        "děti", "škola", "zahrada", "oprava", "nemocnice", "lékař", "procházka", "kolo", "hory", "moře",
        "nápad", "otázka", "odpověď", "riziko", "cíl", "priorita", "migrace", "databáze", "server",
        "aplikace", "vyhledávání", "index", "výkon", "měření", "test", "chyba", "oprava", "vydání",
    ]
    static let syllables = [
        "ka", "to", "ře", "ná", "vy", "mo", "dů", "le", "pá", "ši", "ce", "ro", "zá", "bě", "lu", "hý",
        "ne", "po", "st", "kr", "va", "mi", "jí", "do", "se", "ra", "ko", "tu", "ži", "če", "by", "fa",
    ]
}

/// A small, fast, seeded random number generator, so the Vault is reproducible.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextValue() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in `0..<upperBound`.
    mutating func next(_ upperBound: Int) -> Int {
        Int(nextValue() % UInt64(upperBound))
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
