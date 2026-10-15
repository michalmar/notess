import Foundation

public enum ImagePasteError: LocalizedError, Equatable {
    case unreadableImage

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: "Obrázek ve schránce se nepodařilo převést do formátu PNG."
        }
    }
}
