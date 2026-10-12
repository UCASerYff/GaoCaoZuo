import Foundation
import SwiftUI
import Combine

public enum GaoLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case de = "de"
    case fr = "fr"
    case es = "es"
    case it = "it"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统 (System Default)"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .it: return "Italiano"
        }
    }
}

@MainActor
public final class GaoLocale: ObservableObject {
    public static let shared = GaoLocale()

    @Published public var currentLanguage: GaoLanguage = .system

    public init() {}

    public func setLanguage(_ lang: GaoLanguage) {
        currentLanguage = lang
    }

    public var effectiveLanguage: GaoLanguage {
        if currentLanguage != .system { return currentLanguage }
        let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-HK") || preferred.hasPrefix("zh-TW") { return .zhHant }
        if preferred.hasPrefix("zh") { return .zhHans }
        if preferred.hasPrefix("en") { return .en }
        if preferred.hasPrefix("ja") { return .ja }
        if preferred.hasPrefix("de") { return .de }
        if preferred.hasPrefix("fr") { return .fr }
        if preferred.hasPrefix("es") { return .es }
        if preferred.hasPrefix("it") { return .it }
        return .zhHans
    }

    public static func tr(_ key: String) -> String {
        shared.translate(key)
    }

    public func translate(_ key: String) -> String {
        let lang = effectiveLanguage
        if let dict = Self.translations[lang], let val = dict[key] {
            return val
        }
        if let fallback = Self.translations[.zhHans]?[key] {
            return fallback
        }
        return key
    }

    private static let translations: [GaoLanguage: [String: String]] = [
        .zhHans: [
            "app.title": "搞操作",
            "section.home": "常用",
            "section.files": "文件",
            "section.windows": "窗口",
            "section.archives": "压缩",
            "section.clipboard": "剪贴板",
            "section.tools": "小工具",
            "section.input": "快捷键与手势",
            "section.workflows": "组合操作",
            "section.history": "恢复记录",
            "settings.title": "搞操作设置",
            "window.leftHalf": "左半屏",
            "window.rightHalf": "右半屏",
            "window.topHalf": "上半屏",
            "window.bottomHalf": "下半屏",
            "window.topLeft": "左上角",
            "window.topRight": "右上角",
            "window.bottomLeft": "左下角",
            "window.bottomRight": "右下角",
            "window.thirdLeft": "左侧三分之一",
            "window.thirdCenter": "中间三分之一",
            "window.thirdRight": "右侧三分之一",
            "window.maximize": "铺满工作区",
            "window.center": "窗口居中",
            "window.smaller": "缩小窗口",
            "window.larger": "放大窗口",
            "window.nextDisplay": "移到下一显示器",
            "window.previousDisplay": "移到上一显示器",
            "window.restore": "恢复原位置",
            "archive.create": "压缩为 ZIP",
            "archive.7z": "压缩为 7Z",
            "archive.extract": "直接解压",
            "archive.list": "预览压缩包…",
            "archive.custom": "自定义压缩…",
            "archive.extract.custom": "解压到其他目录…",
            "btn.ok": "确定",
            "btn.cancel": "取消",
            "btn.save": "保存",
            "btn.remove": "移除",
            "btn.add": "添加",
            "btn.close": "关闭"
        ],
        .zhHant: [
            "app.title": "搞操作",
            "section.home": "常用",
            "section.files": "檔案",
            "section.windows": "視窗",
            "section.archives": "壓縮",
            "section.clipboard": "剪貼簿",
            "section.tools": "小工具",
            "section.input": "快速鍵與手勢",
            "section.workflows": "組合操作",
            "section.history": "復原紀錄",
            "settings.title": "搞操作偏好設定",
            "window.leftHalf": "左半邊視窗",
            "window.rightHalf": "右半邊視窗",
            "window.topHalf": "上半邊視窗",
            "window.bottomHalf": "下半邊視窗",
            "window.topLeft": "左上角",
            "window.topRight": "右上角",
            "window.bottomLeft": "左下角",
            "window.bottomRight": "右下角",
            "window.thirdLeft": "左側三分之一",
            "window.thirdCenter": "中央三分之一",
            "window.thirdRight": "右側三分之一",
            "window.maximize": "最大化工作區",
            "window.center": "視窗置中",
            "window.smaller": "縮小視窗",
            "window.larger": "放大視窗",
            "window.nextDisplay": "移至下一個顯示器",
            "window.previousDisplay": "移至上一個顯示器",
            "window.restore": "還原原始位置",
            "archive.create": "壓縮為 ZIP",
            "archive.7z": "壓縮為 7Z",
            "archive.extract": "直接解壓縮",
            "archive.list": "預覽壓縮檔…",
            "archive.custom": "自訂壓縮…",
            "archive.extract.custom": "解壓縮至其他目錄…",
            "btn.ok": "確定",
            "btn.cancel": "取消",
            "btn.save": "儲存",
            "btn.remove": "移除",
            "btn.add": "新增",
            "btn.close": "關閉"
        ],
        .en: [
            "app.title": "GaoCaoZuo",
            "section.home": "Favorites",
            "section.files": "Files",
            "section.windows": "Windows",
            "section.archives": "Archives",
            "section.clipboard": "Clipboard",
            "section.tools": "Tools",
            "section.input": "Shortcuts & Gestures",
            "section.workflows": "Workflows",
            "section.history": "History",
            "settings.title": "GaoCaoZuo Settings",
            "window.leftHalf": "Left Half",
            "window.rightHalf": "Right Half",
            "window.topHalf": "Top Half",
            "window.bottomHalf": "Bottom Half",
            "window.topLeft": "Top Left",
            "window.topRight": "Top Right",
            "window.bottomLeft": "Bottom Left",
            "window.bottomRight": "Bottom Right",
            "window.thirdLeft": "Left Third",
            "window.thirdCenter": "Center Third",
            "window.thirdRight": "Right Third",
            "window.maximize": "Maximize",
            "window.center": "Center Window",
            "window.smaller": "Make Smaller",
            "window.larger": "Make Larger",
            "window.nextDisplay": "Next Display",
            "window.previousDisplay": "Previous Display",
            "window.restore": "Restore Position",
            "archive.create": "Compress to ZIP",
            "archive.7z": "Compress to 7Z",
            "archive.extract": "Extract Here",
            "archive.list": "Preview Archive…",
            "archive.custom": "Custom Compress…",
            "archive.extract.custom": "Extract To…",
            "btn.ok": "OK",
            "btn.cancel": "Cancel",
            "btn.save": "Save",
            "btn.remove": "Remove",
            "btn.add": "Add",
            "btn.close": "Close"
        ],
        .ja: [
            "app.title": "GaoCaoZuo (操作向上)",
            "section.home": "お気に入り",
            "section.files": "ファイル",
            "section.windows": "ウィンドウ",
            "section.archives": "アーカイブ",
            "section.clipboard": "クリップボード",
            "section.tools": "ツール",
            "section.input": "ショートカットとジェスチャ",
            "section.workflows": "ワークフロー",
            "section.history": "履歴",
            "settings.title": "環境設定",
            "window.leftHalf": "左半分",
            "window.rightHalf": "右半分",
            "window.topHalf": "上半分",
            "window.bottomHalf": "下半分",
            "window.topLeft": "左上",
            "window.topRight": "右上",
            "window.bottomLeft": "左下",
            "window.bottomRight": "右下",
            "window.thirdLeft": "左側1/3",
            "window.thirdCenter": "中央1/3",
            "window.thirdRight": "右側1/3",
            "window.maximize": "最大化",
            "window.center": "ウィンドウを中央配置",
            "window.smaller": "ウィンドウを縮小",
            "window.larger": "ウィンドウを拡大",
            "window.nextDisplay": "次のディスプレイへ移動",
            "window.previousDisplay": "前のディスプレイへ移動",
            "window.restore": "元の位置に戻す",
            "archive.create": "ZIP圧縮",
            "archive.7z": "7Z圧縮",
            "archive.extract": "ここに展開",
            "archive.list": "アーカイブをプレビュー…",
            "archive.custom": "カスタム圧縮…",
            "archive.extract.custom": "別の場所に展開…",
            "btn.ok": "OK",
            "btn.cancel": "キャンセル",
            "btn.save": "保存",
            "btn.remove": "削除",
            "btn.add": "追加",
            "btn.close": "閉じる"
        ],
        .de: [
            "app.title": "GaoCaoZuo",
            "section.home": "Favoriten",
            "section.files": "Dateien",
            "section.windows": "Fenster",
            "section.archives": "Archive",
            "section.clipboard": "Zwischenablage",
            "section.tools": "Werkzeuge",
            "section.input": "Tastenkombinationen & Gesten",
            "section.workflows": "Arbeitsabläufe",
            "section.history": "Verlauf",
            "settings.title": "Einstellungen",
            "window.leftHalf": "Linke Hälfte",
            "window.rightHalf": "Rechte Hälfte",
            "window.topHalf": "Obere Hälfte",
            "window.bottomHalf": "Untere Hälfte",
            "window.topLeft": "Oben Links",
            "window.topRight": "Oben Rechts",
            "window.bottomLeft": "Unten Links",
            "window.bottomRight": "Unten Rechts",
            "window.thirdLeft": "Linkes Drittel",
            "window.thirdCenter": "Mittleres Drittel",
            "window.thirdRight": "Rechtes Drittel",
            "window.maximize": "Maximieren",
            "window.center": "Fenster zentrieren",
            "window.smaller": "Verkleinern",
            "window.larger": "Vergrößern",
            "window.nextDisplay": "Nächster Bildschirm",
            "window.previousDisplay": "Vorheriger Bildschirm",
            "window.restore": "Wiederherstellen",
            "archive.create": "Als ZIP komprimieren",
            "archive.7z": "Als 7Z komprimieren",
            "archive.extract": "Hier entpacken",
            "archive.list": "Vorschau anzeigen…",
            "archive.custom": "Benutzerdefinierte Komprimierung…",
            "archive.extract.custom": "Entpacken nach…",
            "btn.ok": "OK",
            "btn.cancel": "Abbrechen",
            "btn.save": "Speichern",
            "btn.remove": "Entfernen",
            "btn.add": "Hinzufügen",
            "btn.close": "Schließen"
        ],
        .fr: [
            "app.title": "GaoCaoZuo",
            "section.home": "Favoris",
            "section.files": "Fichiers",
            "section.windows": "Fenêtres",
            "section.archives": "Archives",
            "section.clipboard": "Presse-papiers",
            "section.tools": "Outils",
            "section.input": "Raccourcis & Gestes",
            "section.workflows": "Flux de travail",
            "section.history": "Historique",
            "settings.title": "Préférences",
            "window.leftHalf": "Moitié gauche",
            "window.rightHalf": "Moitié droite",
            "window.topHalf": "Moitié supérieure",
            "window.bottomHalf": "Moitié inférieure",
            "window.topLeft": "Coin supérieur gauche",
            "window.topRight": "Coin supérieur droit",
            "window.bottomLeft": "Coin inférieur gauche",
            "window.bottomRight": "Coin inférieur droit",
            "window.thirdLeft": "Tiers gauche",
            "window.thirdCenter": "Tiers central",
            "window.thirdRight": "Tiers droit",
            "window.maximize": "Agrandir",
            "window.center": "Centrer la fenêtre",
            "window.smaller": "Réduire",
            "window.larger": "Agrandir",
            "window.nextDisplay": "Écran suivant",
            "window.previousDisplay": "Écran précédent",
            "window.restore": "Restaurer la position",
            "archive.create": "Compresser en ZIP",
            "archive.7z": "Compresser en 7Z",
            "archive.extract": "Extraire ici",
            "archive.list": "Aperçu de l'archive…",
            "archive.custom": "Compression personnalisée…",
            "archive.extract.custom": "Extraire vers…",
            "btn.ok": "OK",
            "btn.cancel": "Annuler",
            "btn.save": "Enregistrer",
            "btn.remove": "Supprimer",
            "btn.add": "Ajouter",
            "btn.close": "Fermer"
        ],
        .es: [
            "app.title": "GaoCaoZuo",
            "section.home": "Favoritos",
            "section.files": "Archivos",
            "section.windows": "Ventanas",
            "section.archives": "Archivos comprimidos",
            "section.clipboard": "Portapapeles",
            "section.tools": "Herramientas",
            "section.input": "Atajos y Gestos",
            "section.workflows": "Flujos de trabajo",
            "section.history": "Historial",
            "settings.title": "Configuración",
            "window.leftHalf": "Mitad izquierda",
            "window.rightHalf": "Mitad derecha",
            "window.topHalf": "Mitad superior",
            "window.bottomHalf": "Mitad inferior",
            "window.topLeft": "Esquina superior izquierda",
            "window.topRight": "Esquina superior derecha",
            "window.bottomLeft": "Esquina inferior izquierda",
            "window.bottomRight": "Esquina inferior derecha",
            "window.thirdLeft": "Tercio izquierdo",
            "window.thirdCenter": "Tercio central",
            "window.thirdRight": "Tercio derecho",
            "window.maximize": "Maximizar",
            "window.center": "Centrar ventana",
            "window.smaller": "Hacer más pequeña",
            "window.larger": "Hacer más grande",
            "window.nextDisplay": "Pantalla siguiente",
            "window.previousDisplay": "Pantalla anterior",
            "window.restore": "Restaurar posición",
            "archive.create": "Comprimir como ZIP",
            "archive.7z": "Comprimir como 7Z",
            "archive.extract": "Extraer aquí",
            "archive.list": "Previsualizar archivo…",
            "archive.custom": "Compresión personalizada…",
            "archive.extract.custom": "Extraer en…",
            "btn.ok": "Aceptar",
            "btn.cancel": "Cancelar",
            "btn.save": "Guardar",
            "btn.remove": "Eliminar",
            "btn.add": "Añadir",
            "btn.close": "Cerrar"
        ],
        .it: [
            "app.title": "GaoCaoZuo",
            "section.home": "Preferiti",
            "section.files": "File",
            "section.windows": "Finestre",
            "section.archives": "Archivi",
            "section.clipboard": "Appunti",
            "section.tools": "Strumenti",
            "section.input": "Scorciatoie e Gesti",
            "section.workflows": "Flussi di lavoro",
            "section.history": "Cronologia",
            "settings.title": "Impostazioni",
            "window.leftHalf": "Metà sinistra",
            "window.rightHalf": "Metà destra",
            "window.topHalf": "Metà superiore",
            "window.bottomHalf": "Metà inferiore",
            "window.topLeft": "In alto a sinistra",
            "window.topRight": "In alto a destra",
            "window.bottomLeft": "In basso a sinistra",
            "window.bottomRight": "In basso a destra",
            "window.thirdLeft": "Terzo sinistro",
            "window.thirdCenter": "Terzo centrale",
            "window.thirdRight": "Terzo destro",
            "window.maximize": "Massimizza",
            "window.center": "Centra finestra",
            "window.smaller": "Riduci",
            "window.larger": "Ingrandisci",
            "window.nextDisplay": "Schermo successivo",
            "window.previousDisplay": "Schermo precedente",
            "window.restore": "Ripristina posizione",
            "archive.create": "Comprimi in ZIP",
            "archive.7z": "Comprimi in 7Z",
            "archive.extract": "Estrai qui",
            "archive.list": "Anteprima archivio…",
            "archive.custom": "Compressione personalizzata…",
            "archive.extract.custom": "Estrai in…",
            "btn.ok": "OK",
            "btn.cancel": "Annulla",
            "btn.save": "Salva",
            "btn.remove": "Rimuovi",
            "btn.add": "Aggiungi",
            "btn.close": "Chiudi"
        ]
    ]
}
