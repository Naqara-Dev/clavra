import AppKit
import SwiftUI

/// The host's runbook beside its terminal: steps to tick, commands to run with a click.
struct RunbookPanel: View {
    var session: Session
    @Bindable var model: AppModel
    @State private var editing = false
    @State private var draft = ""

    private var host: Server.ID { session.server.id }
    private var text: String { model.runbooks.text(for: host) }
    private var blocks: [RunbookBlock] { RunbookBlock.parse(text) }
    private var hasSteps: Bool { blocks.contains { if case .step(_, true, _) = $0 { true } else { false } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Runbook").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if model.isSaved(session.server) {
                    if editing {
                        Button("Done") {
                            model.runbooks.save(draft, for: host)
                            editing = false
                        }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.brass)
                    } else {
                        if hasSteps {
                            icon("arrow.counterclockwise", help: "Untick every step") { model.runbooks.resetSteps(for: host) }
                        }
                        icon("pencil", help: "Edit the runbook (Markdown)") { draft = text; editing = true }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.line).frame(height: 1)
            content
        }
    }

    @ViewBuilder private var content: some View {
        if !model.isSaved(session.server) {
            note("Save this host to keep a runbook with it.")
        } else if editing {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                Text("# Heading · - [ ] a step · ``` a command to run ``` · $ a one-line command")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
            .padding(12)
        } else if text.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("No runbook for \(session.server.title) yet. Write down how to deploy it, restart it, or get it out of trouble; commands in it run with a click, through the same guard as typing.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Start One") { draft = RunbookStore.starter; editing = true }.buttonStyle(BrassButtonStyle())
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks) { block in view(for: block) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func view(for block: RunbookBlock) -> some View {
        switch block {
        case .heading(let title, let level, _):
            Text(title).font(.system(size: level <= 1 ? 14 : 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, level <= 1 ? 6 : 2)
        case .step(let title, let done, let line):
            Button { model.runbooks.toggle(line: line, for: host) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12)).foregroundStyle(done ? Theme.color(for: .personal) : Theme.tertiary)
                    Text(inline(title)).font(.system(size: 12.5)).foregroundStyle(done ? Theme.tertiary : Theme.ink)
                        .strikethrough(done, color: Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .code(let command, _):
            CodeBlock(command: command, live: session.isLive) { run in
                session.type(command, run: run)
            }
        case .text(let text, _):
            Text(inline(text)).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A command in the runbook: Run types it and presses Return; Type leaves it on the line.
private struct CodeBlock: View {
    var command: String
    var live: Bool
    var send: (Bool) -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            HStack(spacing: 12) {
                Button { send(true) } label: { Label("Run", systemImage: "play.fill") }
                    .foregroundStyle(Theme.brass).disabled(!live)
                    .help(command.contains("\n") ? "Types every line, pressing Return after each" : "Types it and presses Return")
                if !command.contains("\n") {
                    Button { send(false) } label: { Label("Type", systemImage: "text.cursor") }
                        .foregroundStyle(Theme.secondary).disabled(!live)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .opacity(hovering || !live ? 1 : 0.75)
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.terminal))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
        .onHover { hovering = $0; if !$0 { copied = false } }
    }
}
