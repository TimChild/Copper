import Foundation
import Testing
@testable import Search

// Settings › Passwords › Import and export (Fork/Credentials/PasswordCSV.swift):
// what a file must look like before anything is saved, what the import says,
// and that an export is a file the import — and other managers — take back.

@Test func exportsFromEveryManagerPassTheHeaderCheck() {
    let headers = [
        "name,url,username,password,note",                                   // Chrome and Copper
        "Title,URL,Username,Password,Notes,OTPAuth",                          // Safari, Apple Passwords
        "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes",   // a password manager
        "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp", // another
        "\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\"", // another browser
        "url,username,password,totp,extra,name,grouping,fav",                 // another manager
    ]
    for header in headers {
        #expect(PasswordCSV.problem(with: header + "\nhttps://a.test,me,pw\n") == nil, "\(header)")
    }
}

@Test func badFilesSayWhatIsWrongAndWhatToDo() {
    #expect(PasswordCSV.problem(with: "") == "That file is empty")
    #expect(PasswordCSV.problem(with: "   \n\n") == "That file is empty")
    #expect(PasswordCSV.problem(with: "just some notes\nmore words")?.hasPrefix("That isn't a passwords CSV") == true)
    #expect(PasswordCSV.problem(with: "name,url,username\nx,https://a.test,me") == "That CSV has no password column — export it again as a passwords CSV")
    #expect(PasswordCSV.problem(with: "name,email,phone\nx,y,z") == "That CSV has no website or password column — export it again as a passwords CSV")
    #expect(PasswordCSV.problem(with: "a,b\n1,2") == "That CSV has no website, username or password column — export it again as a passwords CSV")
}

@Test func firstRecordReadsQuotesAndStopsAtTheLine() {
    #expect(PasswordCSV.firstRecord("a,\"b,c\",\"d \"\"e\"\"\"\nx,y") == ["a", "b,c", "d \"e\""])
    #expect(PasswordCSV.firstRecord("\"multi\nline\",b\nnext") == ["multi\nline", "b"])
    #expect(PasswordCSV.firstRecord("one column only") == nil)
}

@Test func textComesOutOfTheEncodingsExportsUse() {
    #expect(PasswordCSV.text(of: Data("\u{FEFF}url,username,password".utf8)) == "url,username,password")
    let utf16 = "url,username,password".data(using: .utf16)!
    #expect(PasswordCSV.text(of: utf16) == "url,username,password")
    #expect(PasswordCSV.text(of: Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x08])) == nil) // a zip is not text
    #expect(PasswordCSV.text(of: Data()) == "")
}

@Test func importSentences() {
    #expect(PasswordCSV.Outcome(kept: 3, skipped: 0).sentence == "3 passwords imported")
    #expect(PasswordCSV.Outcome(kept: 1, skipped: 0).sentence == "1 password imported")
    #expect(PasswordCSV.Outcome(kept: 2, skipped: 1).sentence == "2 passwords imported, 1 skipped (no site or no password)")
    #expect(PasswordCSV.Outcome(kept: 0, skipped: 0).sentence == "That file has no passwords in it")
    #expect(PasswordCSV.Outcome(kept: 0, skipped: 4).sentence == "Nothing imported — none of its 4 rows has both a site and a password")
    #expect(PasswordCSV.Outcome(kept: 0, skipped: 1).sentence == "Nothing imported — its one row has no site or no password")
    #expect(PasswordCSV.Outcome(refused: "That file is empty").sentence == "That file is empty")
}

@Test func exportQuotesWhatNeedsIt() {
    let csv = PasswordCSV.csv([
        Login(host: "a.test", user: "me", password: "plain", used: nil),
        Login(host: "b.test", user: "you", password: "has,comma \"and quotes\"\nand a line", used: nil),
    ])
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.first == "name,url,username,password,note")
    #expect(lines[1] == "a.test,https://a.test/,me,plain,")
    #expect(csv.contains("\"has,comma \"\"and quotes\"\"\nand a line\""))
    // What Copper writes, Copper's own check takes back.
    #expect(PasswordCSV.problem(with: csv) == nil)
    #expect(PasswordCSV.firstRecord(csv) == ["name", "url", "username", "password", "note"])
}

@Test func exportSentence() {
    #expect(PasswordCSV.exportSentence(1, refused: 0, file: "x.csv") == "1 password exported to x.csv")
    #expect(PasswordCSV.exportSentence(5, refused: 2, file: "x.csv") == "5 passwords exported to x.csv — 2 the keychain wouldn't give up")
}
