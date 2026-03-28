import SwiftUI

struct ContentView: View {
    @StateObject private var diagnostics = DiagnosticsViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("SmartNews to GoodNotes")
                        .font(.largeTitle.bold())

                    Text("SmartNewsや他のニュースアプリの共有シートからURLを受け取り、記事を読みやすいPDFに整形してGoodNotesへ渡すためのアプリです。")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 12) {
                        Label("SmartNewsで記事を開く", systemImage: "1.circle.fill")
                        Label("共有ボタンからこのアプリ拡張を選ぶ", systemImage: "2.circle.fill")
                        Label("PDF生成後にGoodNotesへ共有する", systemImage: "3.circle.fill")
                    }
                    .font(.headline)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("実装メモ")
                            .font(.title3.bold())
                        Text("・Share ExtensionでURLを受け取り、HTMLを取得")
                        Text("・本文抽出は軽量Readability + フォールバック方式")
                        Text("・PDFはA4サイズ相当で余白を広めに確保")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("診断ログ")
                                .font(.title3.bold())
                            Spacer()
                            Button("更新") {
                                diagnostics.reload()
                            }
                            Button("消去", role: .destructive) {
                                diagnostics.clear()
                            }
                        }

                        if AppGroupConfig.identifier == nil {
                            Text("現在はApp Group未設定です。ホストアプリ内ログは表示できますが、共有拡張ログをこの画面と共有するにはApp Group設定が必要です。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if diagnostics.entries.isEmpty {
                            Text("ログはまだありません。共有拡張を実行後に更新してください。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(diagnostics.entries) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(entry.level)  \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(entry.message)
                                        .font(.footnote.monospaced())
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Home")
            .onAppear {
                diagnostics.reload()
            }
        }
    }
}

#Preview {
    ContentView()
}
