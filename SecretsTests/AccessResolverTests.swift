import Foundation
import Testing
@testable import Secrets

struct AccessResolverTests {
    private func grant(_ path: String) -> FolderGrant {
        FolderGrant(id: UUID(), path: path, projectID: UUID(), addedAt: .now, wroteMarker: false)
    }

    @Test func matchesExactFolder() {
        let accelerate = grant("/Users/me/repos/accelerate")
        #expect(AccessResolver.grant(for: "/Users/me/repos/accelerate", in: [accelerate]) == accelerate)
    }

    @Test func matchesSubfolders() {
        let accelerate = grant("/Users/me/repos/accelerate")
        #expect(AccessResolver.grant(for: "/Users/me/repos/accelerate/apps/web", in: [accelerate]) == accelerate)
    }

    @Test func doesNotMatchSiblingWithSharedPrefix() {
        let accelerate = grant("/Users/me/repos/accelerate")
        #expect(AccessResolver.grant(for: "/Users/me/repos/accelerate-old", in: [accelerate]) == nil)
    }

    @Test func doesNotMatchParentFolder() {
        let accelerate = grant("/Users/me/repos/accelerate")
        #expect(AccessResolver.grant(for: "/Users/me/repos", in: [accelerate]) == nil)
    }

    @Test func mostSpecificGrantWins() {
        let repos = grant("/Users/me/repos")
        let accelerate = grant("/Users/me/repos/accelerate")
        #expect(AccessResolver.grant(for: "/Users/me/repos/accelerate/src", in: [repos, accelerate]) == accelerate)
        #expect(AccessResolver.grant(for: "/Users/me/repos/other", in: [repos, accelerate]) == repos)
    }

    @Test func normalizesDotSegments() {
        let accelerate = grant("/Users/me/repos/accelerate")
        #expect(AccessResolver.grant(for: "/Users/me/repos/other/../accelerate/./src", in: [accelerate]) == accelerate)
    }
}

struct ServiceInputTests {
    @Test func parsesDomains() {
        #expect(ServiceInput.domain(from: "cloudflare.com") == "cloudflare.com")
        #expect(ServiceInput.domain(from: "https://www.cloudflare.com/dashboard") == "cloudflare.com")
        #expect(ServiceInput.domain(from: "  dash.cloudflare.com ") == "dash.cloudflare.com")
        #expect(ServiceInput.domain(from: "Cloudflare") == nil)
        #expect(ServiceInput.domain(from: "App Store Connect") == nil)
    }

    @Test func derivesDisplayNames() {
        #expect(ServiceInput.displayName(forDomain: "dash.cloudflare.com") == "Cloudflare")
        #expect(ServiceInput.displayName(forDomain: "render.com") == "Render")
        #expect(ServiceInput.displayName(forDomain: "example.co.uk") == "Example")
    }

    @Test func matchesTemplates() {
        #expect(ServiceTemplate.match(name: "cloudflare", domain: nil) == .cloudflare)
        #expect(ServiceTemplate.match(name: "x", domain: "dash.cloudflare.com") == .cloudflare)
        #expect(ServiceTemplate.match(name: "x", domain: "appstoreconnect.apple.com") == .appStoreConnect)
        #expect(ServiceTemplate.match(name: "Render", domain: "render.com") == nil)
    }
}

struct IconLinkTests {
    @Test @MainActor func prefersAppleTouchIconThenLargestSize() {
        let html = """
            <link rel="icon" href="/favicon-16.png" sizes="16x16">
            <link rel="icon" href="/favicon-64.png" sizes="64x64">
            <link rel="mask-icon" href="/mask.svg">
            <link href="https://cdn.example.com/touch.png" rel="apple-touch-icon">
            """
        let urls = IconFetcher.iconLinks(in: html, baseURL: URL(string: "https://example.com/")!)
        #expect(urls.map(\.absoluteString) == [
            "https://cdn.example.com/touch.png",
            "https://example.com/favicon-64.png",
            "https://example.com/favicon-16.png",
        ])
    }
}

struct UpdatePolicyTests {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    @Test func permitsOnlySignedReleaseBuilds() {
        #expect(UpdatePolicy.permitsUpdates(identifier: "com.torbensko.secrets", channel: "Release", feed: UpdatePolicy.feed, publicKey: key))
        #expect(!UpdatePolicy.permitsUpdates(identifier: "com.torbensko.secrets", channel: "Development", feed: UpdatePolicy.feed, publicKey: key))
        #expect(!UpdatePolicy.permitsUpdates(identifier: "com.torbensko.secrets", channel: "Release", feed: UpdatePolicy.feed, publicKey: ""))
        #expect(!UpdatePolicy.permitsUpdates(identifier: "com.example.other", channel: "Release", feed: UpdatePolicy.feed, publicKey: key))
    }
}
