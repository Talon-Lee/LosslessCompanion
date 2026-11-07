//
//  LocalizationTests.swift
//  LosslessCompanionTests
//

import XCTest
@testable import LosslessCompanion

final class LocalizationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    private func englishFormat(_ key: String) throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func testLanguageCodes() {
        XCTAssertEqual(AppLanguage(code: nil), .system)
        XCTAssertEqual(AppLanguage(code: "ja"), .system)
        XCTAssertEqual(AppLanguage(code: "zh-Hans"), .system)
        XCTAssertEqual(AppLanguage(code: "en"), .english)
        XCTAssertEqual(AppLanguage(code: "en-GB"), .english)
        XCTAssertEqual(AppLanguage(code: "zh-Hant"), .traditionalChinese)
        XCTAssertEqual(AppLanguage(code: "zh-Hant-TW"), .traditionalChinese)
    }

    func testEnglishPluralsFollowEachCount() throws {
        let format = try englishFormat("%lld 張專輯，%lld 首歌曲")

        XCTAssertEqual(String(format: format, locale: english, 1, 1), "1 album, 1 song")
        XCTAssertEqual(String(format: format, locale: english, 2, 5_337), "2 albums, 5,337 songs")
    }

    func testEnglishKeepsArgumentsAroundAPlural() throws {
        let format = try englishFormat("%@，%lld 首，%@")

        XCTAssertEqual(String(format: format, locale: english, "2024", 1, "40 min"), "2024, 1 track, 40 min")
    }

    func testFieldLabelsAreSingularInEnglish() throws {
        XCTAssertEqual(try englishFormat("專輯"), "Albums")
        XCTAssertEqual(try englishFormat("field.album"), "Album")
    }
}
