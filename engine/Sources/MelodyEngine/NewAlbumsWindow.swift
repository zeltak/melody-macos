// SPDX-License-Identifier: GPL-3.0-only
//
// New Album Actions: what is done with each album new to the library --
// ReplayGain, a rating for its tracks, a command of the user's own. Saved
// in the app's defaults; the controller follows the engine accordingly.

import AppKit
import MelodyEngineCore

final class NewAlbumsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let saved: (NewAlbumActions) -> Void

    private let enabled = NSButton(checkboxWithTitle: "Act on each album new to the library", target: nil, action: nil)
    private let replayGain = NSButton(checkboxWithTitle: "Measure and write ReplayGain", target: nil, action: nil)
    private let gainKind = NSPopUpButton()
    private let truePeak = NSButton(checkboxWithTitle: "True peak", target: nil, action: nil)
    private let gainPlace = NSPopUpButton()
    private let rate = NSButton(checkboxWithTitle: "Rate its tracks", target: nil, action: nil)
    private let rating = NSPopUpButton()
    private let onlyUnrated = NSButton(checkboxWithTitle: "Only tracks without a rating", target: nil, action: nil)
    private let runCommand = NSButton(checkboxWithTitle: "Run a command", target: nil, action: nil)
    private let command = NSTextField()

    init(actions: NewAlbumActions, saved: @escaping (NewAlbumActions) -> Void) {
        self.saved = saved
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "New Album Actions"
        window.isReleasedWhenClosed = false
        window.delegate = self

        gainKind.addItems(withTitles: ["Album and track gain", "Track gain only"])
        gainPlace.addItems(withTitles: ["Into the files' tags", "Beside the files (sidecar); files untouched"])
        for value in 1...10 {
            let stars = String(repeating: "★", count: value / 2) + (value % 2 == 1 ? "½" : "")
            rating.addItem(withTitle: "\(stars)  (\(value) of 10)")
            rating.lastItem?.tag = value
        }
        command.placeholderString = "e.g. /Users/me/bin/tag-album {}"
        command.lineBreakMode = .byTruncatingMiddle
        for toggle in [enabled, replayGain, rate, runCommand] {
            toggle.target = self
            toggle.action = #selector(changed)
        }

        let note = { (text: String) -> NSTextField in
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 460
            return label
        }
        let heading = { (text: String) -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }
        let indented = { (views: [NSView]) -> NSStackView in
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            return stack
        }
        let row = { (label: String, control: NSView) -> NSStackView in
            let stack = NSStackView(views: [NSTextField(labelWithString: label), control])
            stack.spacing = 8
            return stack
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = 8

        command.translatesAutoresizingMaskIntoConstraints = false
        command.widthAnchor.constraint(equalToConstant: 440).isActive = true

        let content = NSStackView(views: [
            enabled,
            note("Once an album is whole in the library — added by a rescan or a copy into the music folder — "
                 + "the engine does these for it, one album at a time. Albums added while this app is not running are left as they are."),
            heading("ReplayGain"),
            indented([replayGain, row("Gain:", gainKind), truePeak, row("Written:", gainPlace)]),
            heading("Rating"),
            indented([rate, row("Rating:", rating), onlyUnrated]),
            heading("Command"),
            indented([runCommand, command,
                      note("Run by /bin/sh after the above. {} is the album's folder, quoted; "
                           + "MELODY_ALBUM_FOLDER, MELODY_ALBUM_ARTIST, MELODY_ALBUM_TITLE and MELODY_ALBUM_DATE are set.")]),
            buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        content.widthAnchor.constraint(equalToConstant: 520).isActive = true

        show(actions)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func show(_ actions: NewAlbumActions) {
        enabled.state = actions.enabled ? .on : .off
        replayGain.state = actions.replayGain ? .on : .off
        gainKind.selectItem(at: actions.albumGain ? 0 : 1)
        truePeak.state = actions.truePeak ? .on : .off
        gainPlace.selectItem(at: actions.sidecar ? 1 : 0)
        rate.state = actions.rate ? .on : .off
        rating.selectItem(withTag: (1...10).contains(actions.rating) ? actions.rating : 4)
        onlyUnrated.state = actions.onlyUnrated ? .on : .off
        runCommand.state = actions.runCommand ? .on : .off
        command.stringValue = actions.command
        changed()
    }

    private var current: NewAlbumActions {
        var actions = NewAlbumActions()
        actions.enabled = enabled.state == .on
        actions.replayGain = replayGain.state == .on
        actions.albumGain = gainKind.indexOfSelectedItem == 0
        actions.truePeak = truePeak.state == .on
        actions.sidecar = gainPlace.indexOfSelectedItem == 1
        actions.rate = rate.state == .on
        actions.rating = rating.selectedTag()
        actions.onlyUnrated = onlyUnrated.state == .on
        actions.runCommand = runCommand.state == .on
        actions.command = command.stringValue
        return actions
    }

    @objc private func changed() {
        let on = enabled.state == .on
        for control in [replayGain, rate, runCommand] as [NSControl] { control.isEnabled = on }
        let gain = on && replayGain.state == .on
        for control in [gainKind, truePeak, gainPlace] as [NSControl] { control.isEnabled = gain }
        let rated = on && rate.state == .on
        for control in [rating, onlyUnrated] as [NSControl] { control.isEnabled = rated }
        command.isEnabled = on && runCommand.state == .on
    }

    @objc private func save() {
        saved(current)
        window.close()
    }

    @objc private func cancelled() {
        window.close()
    }
}
