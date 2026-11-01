import Foundation

func visualWidth(_ s: String) -> Int {
    s.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
}

extension String {
    func prefix(whileVisualWidth limit: Int) -> Substring {
        var w = 0
        return prefix(while: { char in
            let cw = char.isASCII ? 1 : 2
            defer { w += cw }
            return w + cw <= limit
        })
    }

    func suffix(whileVisualWidth limit: Int) -> Substring {
        var w = 0
        var count = 0
        for char in self.reversed() {
            let cw = char.isASCII ? 1 : 2
            if w + cw > limit { break }
            w += cw
            count += 1
        }
        return self.suffix(count)
    }
}
