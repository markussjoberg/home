import SwiftUI
import MapKit
import NosteCore

/// Merisää kartalla: FMI:n aaltopoijut ja tuuliasemat chippeinä (kuten
/// Ilmatieteen laitoksen Merisää-näkymässä) — arvo + suuntanuoli.
final class SeaStateAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case buoy
        case station
    }

    let kind: Kind
    let data: ServerClient.SeaStation
    let coordinate: CLLocationCoordinate2D

    init(kind: Kind, data: ServerClient.SeaStation) {
        self.kind = kind
        self.data = data
        self.coordinate = CLLocationCoordinate2D(latitude: data.latitude, longitude: data.longitude)
    }

    var chipText: String {
        switch kind {
        case .buoy:
            let height = data.waveHeight.map { String(format: "%.1f m", $0) } ?? "–"
            if let temp = data.waterTemp {
                return "\(height) · \(String(format: "%.0f°", temp))"
            }
            return height
        case .station:
            guard let speed = data.windSpeed else { return "–" }
            if let gust = data.windGust {
                return String(format: "%.0f/%.0f m/s", speed, gust)
            }
            return String(format: "%.0f m/s", speed)
        }
    }

    /// Suunta josta tuuli/aalto tulee; nuoli osoittaa menosuuntaan (+180°).
    var arrowDirection: Double? {
        switch kind {
        case .buoy: return data.waveDirection
        case .station: return data.windDirection
        }
    }

    var chipColor: UIColor {
        kind == .buoy ? .systemBlue : .systemGreen
    }
}

/// Pieni chippi: suuntanuoli + arvo, pillitausta.
final class SeaChipAnnotationView: MKAnnotationView {
    private let label = UILabel()
    private let arrow = UIImageView()
    private let pill = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .rectangle

        pill.layer.cornerRadius = 11
        pill.layer.borderWidth = 1
        pill.layer.borderColor = UIColor.black.withAlphaComponent(0.1).cgColor

        arrow.image = UIImage(systemName: "arrow.up",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        arrow.contentMode = .center
        label.font = .systemFont(ofSize: 12, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [arrow, label])
        stack.axis = .horizontal
        stack.spacing = 3
        stack.alignment = .center

        addSubview(pill)
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ annotation: SeaStateAnnotation) {
        label.text = annotation.chipText
        label.textColor = .white
        arrow.tintColor = .white
        pill.backgroundColor = annotation.chipColor.withAlphaComponent(0.92)
        if let direction = annotation.arrowDirection {
            arrow.isHidden = false
            arrow.transform = CGAffineTransform(rotationAngle: (direction + 180) * .pi / 180)
        } else {
            arrow.isHidden = true
        }
        pill.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        let size = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        pill.frame = CGRect(origin: .zero, size: size)
        frame = pill.frame
        centerOffset = .zero
    }
}
