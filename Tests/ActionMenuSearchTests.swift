import Foundation

@main
@MainActor
struct ActionMenuSearchTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        let empty = ActionMenuSearchQuery("  \n")
        expect(empty.isEmpty, "a whitespace-only query is empty")
        expect(empty.score("Paste as Plain Text") != nil, "a blank query keeps every action")

        let plainText = ActionMenuSearchQuery("ptxt")
        expect(!plainText.isEmpty, "a meaningful query is not empty")
        expect(
            plainText.score("Paste as Plain Text") != nil,
            "a non-contiguous query uses the launcher's fuzzy matcher")
        expect(plainText.score("Copy to Clipboard") == nil, "unmatched actions are removed")
        let ranked = ActionMenuSearchQuery("paste")
        expect(
            ranked.score("Paste")! > ranked.score("Paste as Plain Text")!,
            "the strongest fuzzy result can drive the menu highlight")

        let folded = ActionMenuSearchQuery("resume")
        expect(folded.score("Résumé") != nil, "matching stays case- and diacritic-insensitive")

        let preserved = ActionMenuSearchQuery("  paste  ")
        expect(preserved.score("Paste to Finder") != nil, "outer whitespace does not affect matching")

        expect(ActionMenuSearchQuery("fuzhi").score("复制") != nil, "Chinese actions match full pinyin")
        expect(ActionMenuSearchQuery("fz").score("复制") != nil, "Chinese actions match pinyin initials")
        expect(
            ActionMenuSearchQuery("copy").score("复制", englishTitle: "Copy") != nil,
            "a localized action matches its English source name")
        expect(ActionMenuSearchQuery("复制").score("复制") != nil, "Chinese titles remain searchable")
        expect(
            ActionMenuSearchQuery("  COPY  ").score("复制", englishTitle: "Copy") != nil,
            "English source names share query trimming and case folding")
        expect(
            ActionMenuSearchQuery("cpcl").score("复制到剪贴板", englishTitle: "Copy to Clipboard") != nil,
            "English source names support fuzzy matching")
        expect(
            ActionMenuSearchQuery("copy").score("复制") == nil,
            "Chinese-only extension titles are not translated")
        expect(
            ActionMenuSearchQuery("remove").score("删除", englishTitle: "Delete") == nil,
            "English source names do not introduce synonyms")
        expect(
            ActionMenuSearchQuery("fz").score("复制", englishTitle: "Copy") != nil,
            "an English source name does not replace the pinyin aliases")
        expect(
            ActionMenuSearchQuery("yinyue").score("播放音乐") != nil,
            "pinyin uses the existing word-aware readings")
        expect(
            ActionMenuSearchQuery("fuzhi").score("复制")!
                > ActionMenuSearchQuery("fuzhi").score("复制到剪贴板")!,
            "the strongest pinyin result can drive the menu highlight")
        expect(
            ActionMenuSearchQuery("copy").score("复制", englishTitle: "Copy")!
                > ActionMenuSearchQuery("copy").score("复制到剪贴板", englishTitle: "Copy to Clipboard")!,
            "the strongest English result can drive the menu highlight")
        expect(
            empty.score("复制", englishTitle: "Copy") == 0,
            "a blank query retains localized actions without preferring an alias")

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
