import SwiftUI

struct ContentView: View {
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
                        Text("・本文抽出はSwiftSoupベースの簡易Readability方式")
                        Text("・PDFはA4サイズ相当で余白を広めに確保")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
                .padding(24)
            }
            .navigationTitle("Home")
        }
    }
}

#Preview {
    ContentView()
}
