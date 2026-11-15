import Foundation

@main
enum Build87OriginalEnlarger96Validation {
    enum Failure:Error {case invalid(String)}
    static func vector(_ obj:[String:Any],_ key:String) throws -> [Double] {
        guard let x=obj[key] as? [NSNumber] else {
            throw Failure.invalid("No original Python "+key)
        }
        return x.map{$0.doubleValue}
    }
    static func number(_ obj:[String:Any],_ key:String) throws -> Double {
        guard let n=obj[key] as? NSNumber else {
            throw Failure.invalid("No original Python scalar "+key)
        }
        return n.doubleValue
    }
    static func close(
        _ actual:[Double],_ source:[Double],_ label:String,
        limit:Double=4e-11
    ) throws -> Double {
        guard actual.count==source.count else {
            throw Failure.invalid(label+" shape mismatch")
        }
        var worst=0.0
        for i in actual.indices {
            let error=abs(actual[i]-source[i])
            guard error.isFinite,error<=limit else {
                throw Failure.invalid(
                    "\(label) #\(i) Swift=\(actual[i]) Python=\(source[i]) " +
                    "Δ=\(error)"
                )
            }
            worst=max(worst,error)
        }
        return worst
    }

    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Missing original 81nm source oracle")
        }
        let data=try Data(
            contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])
        )
        guard let object=try JSONSerialization.jsonObject(with:data)
                as? [String:Any],
              let cases=object["cases"] as? [[String:Any]],
              cases.count==96 else {
            throw Failure.invalid("Need all 96 original film-paper setups")
        }
        var filterWorst=0.0,flashWorst=0.0,printWorst=0.0
        var overOneFlash=0
        for (index,item) in cases.enumerated() {
            guard let film=item["film"] as? String,
                  let paper=item["paper"] as? String,
                  let normalize=item["normalize"] as? Bool,
                  let compensate=item["compensate"] as? Bool,
                  let baseValid=item["baseValid"] as? [Bool],
                  let sourceSens=item["sensitivity"] as? [[NSNumber]] else {
                throw Failure.invalid("Bad source enlarger stock config")
            }
            var cfg=OriginalPrintOptics.Settings()
            cfg.enabled=true
            cfg.neutralPrintFiltersFromDatabase=false
            let cc=try vector(item,"neutral")
            let shifts=try vector(item,"shifts")
            let preShifts=try vector(item,"preShifts")
            let flash=try number(item,"flash")
            cfg.cyanNeutral=cc[0]
            cfg.magentaNeutral=cc[1]
            cfg.yellowNeutral=cc[2]
            cfg.cyanShift=shifts[0]
            cfg.magentaShift=shifts[1]
            cfg.yellowShift=shifts[2]
            cfg.preflashMagentaShift=preShifts[0]
            cfg.preflashYellowShift=preShifts[1]
            cfg.preflashExposure=flash
            cfg.normalizePrintExposure=normalize
            cfg.printExposureCompensation=compensate
            guard cfg.isValid else {
                throw Failure.invalid("Source legal CC/flash unexpectedly rejected")
            }
            if flash>1 {overOneFlash+=1}
            let neutral=try OriginalPrintOptics.sourceNeutralCC(
                filmID:film,paperID:paper,settings:cfg,
                neutralByPair:[:]
            )
            _=try close(neutral,cc,"source custom neutral CC")
            let prepared=OriginalPrintOptics.prepare(
                source:try vector(item,"light"),
                neutralCC:neutral,settings:cfg,
                filmBase:try vector(item,"base"),
                filmBaseValid:baseValid,
                paperSensitivity:sourceSens.map{$0.map{$0.doubleValue}}
            )
            filterWorst=max(filterWorst,try close(
                prepared.printIlluminant,
                try vector(item,"filtered"),
                "original 81nm CMY filters #\(index)"
            ))
            flashWorst=max(flashWorst,try close(
                prepared.preflashRaw,try vector(item,"sourcePreflash"),
                "original 81nm film-base preflash #\(index)"
            ))
            let reference=OriginalPrintOptics.referenceDivisor(
                midgrayRaw:try vector(item,"midRaw"),
                compensatedRaw:try vector(item,"compRaw"),
                normalize:normalize,compensate:compensate
            )
            printWorst=max(printWorst,try close(
                [reference],[try number(item,"sourceDivisor")],
                "source four reference modes #\(index)"
            ))
            printWorst=max(printWorst,try close(
                OriginalPrintOptics.paperLogExposure(
                    raw:try vector(item,"raw"),
                    reference:reference,
                    preflash:prepared.preflashRaw,
                    printEV:try number(item,"paperEV")
                ),
                try vector(item,"final"),
                "source Python PrintingStage.expose #\(index)"
            ))
        }
        guard overOneFlash>0 else {
            throw Failure.invalid("Missing source legal preflash >1 case")
        }
        var lens=OriginalPrintOptics.Settings()
        lens.cyanNeutral=17
        lens.magentaNeutral=37
        lens.yellowNeutral=52
        lens.illuminant = .thKG3L
        let noDatabase=try OriginalPrintOptics.sourceNeutralCC(
            filmID:"kodak_portra_400",paperID:"kodak_portra_endura",
            settings:lens,
            neutralByPair:["kodak_portra_400|kodak_portra_endura":[0,10,20]]
        )
        _=try close(noDatabase,[17,37,52],
                    "TH-KG3-L must not inherit TH-KG3 neutral database row")
        print("BUILD87 SOURCE 81nm ENLARGER PASS: 96 film-paper cases " +
              "× 81 wavelengths, 4 normalization modes, 3 preflash " +
              "levels including >1. Filter max=\(filterWorst), " +
              "preflash max=\(flashWorst), print max=\(printWorst); " +
              "no unsupported clipping of legal source settings.")
    }
}
