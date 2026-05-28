//
//  TranslateButton.swift
//  NetNewsWire-iOS
//

import UIKit

enum TranslateButtonState {
    case off
    case animated
    case on
    case error
}

final class TranslateButton: UIButton {

    private let activityIndicator: UIActivityIndicatorView = {
        let i = UIActivityIndicatorView(style: .medium)
        i.hidesWhenStopped = true
        i.translatesAutoresizingMaskIntoConstraints = false
        return i
    }()

    private static let offImage = UIImage(systemName: "character.book.closed")
    private static let onImage  = UIImage(systemName: "character.book.closed.fill")
    private static let errorImage = UIImage(systemName: "exclamationmark.triangle")

    var buttonState: TranslateButtonState = .off {
        didSet {
            guard buttonState != oldValue else { return }
            switch buttonState {
            case .off:
                activityIndicator.stopAnimating()
                isUserInteractionEnabled = true
                setImage(Self.offImage, for: .normal)
            case .animated:
                setImage(nil, for: .normal)
                activityIndicator.startAnimating()
                isUserInteractionEnabled = false
            case .on:
                activityIndicator.stopAnimating()
                isUserInteractionEnabled = true
                setImage(Self.onImage, for: .normal)
            case .error:
                activityIndicator.stopAnimating()
                isUserInteractionEnabled = true
                setImage(Self.errorImage, for: .normal)
            }
        }
    }

    override var accessibilityLabel: String? {
        get {
            switch buttonState {
            case .off:      return NSLocalizedString("Translate", comment: "Translate")
            case .animated: return NSLocalizedString("Translating", comment: "Translating")
            case .on:       return NSLocalizedString("Translated", comment: "Translated")
            case .error:    return NSLocalizedString("Translation error", comment: "Translation error")
            }
        }
        set { super.accessibilityLabel = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Match ArticleExtractorButton's expanded hit area.
        let expanded = bounds.insetBy(dx: -20, dy: -20)
        return expanded.contains(point)
    }

    private func commonInit() {
        addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setImage(Self.offImage, for: .normal)
    }
}
