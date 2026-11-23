import Foundation

/// Time zone names: abbreviations ("PST"), regions ("PT") and cities ("Oslo", "New York").
enum Zones {
    struct Match {
        var zones: [ZoneLit]
    }

    private static func fixed(_ hours: Double, _ label: String) -> ZoneLit {
        ZoneLit(zone: TimeZone(secondsFromGMT: Int(hours * 3600))!, label: label)
    }

    private static func named(_ id: String, _ label: String) -> ZoneLit {
        ZoneLit(zone: TimeZone(identifier: id)!, label: label)
    }

    /// Abbreviations; standard-time ones are fixed offsets, region names follow DST.
    private static let abbreviations: [String: [ZoneLit]] = [
        "utc": [fixed(0, "UTC")], "gmt": [fixed(0, "GMT")], "z": [fixed(0, "UTC")],
        "cet": [named("Europe/Oslo", "CET")], "cest": [fixed(2, "CEST")],
        "pst": [fixed(-8, "PST")], "pdt": [fixed(-7, "PDT")], "pt": [named("America/Los_Angeles", "Pacific time")],
        "mst": [fixed(-7, "MST")], "mdt": [fixed(-6, "MDT")], "mt": [named("America/Denver", "Mountain time")],
        "est": [fixed(-5, "EST (UTC−5)"), named("America/New_York", "New York time")],
        "edt": [fixed(-4, "EDT")], "et": [named("America/New_York", "Eastern time")],
        "cst": [named("America/Chicago", "US Central"), named("Asia/Shanghai", "China Standard Time")],
        "cdt": [fixed(-5, "CDT")], "ct": [named("America/Chicago", "Central time")],
        "ist": [
            named("Asia/Kolkata", "India Standard Time"), named("Asia/Jerusalem", "Israel Standard Time"),
            named("Europe/Dublin", "Irish time"),
        ],
        "jst": [named("Asia/Tokyo", "JST")], "kst": [named("Asia/Seoul", "KST")],
        "aest": [fixed(10, "AEST")], "aedt": [fixed(11, "AEDT")], "bst": [named("Europe/London", "British time")],
        "eet": [named("Europe/Helsinki", "EET")], "wet": [named("Europe/Lisbon", "WET")],
        "hst": [fixed(-10, "HST")], "akst": [fixed(-9, "AKST")], "sgt": [fixed(8, "SGT")], "hkt": [fixed(8, "HKT")],
    ]

    /// Lowercase abbreviations that are also ordinary words are only zones in capitals.
    private static let capitalsOnly: Set<String> = [
        "pt", "mt", "et", "ct", "z", "bst", "eet", "wet", "ist", "cet", "est", "mst", "hst",
    ]

    private static let extraCities: [String: String] = [
        "oslo": "Europe/Oslo", "bergen": "Europe/Oslo", "trondheim": "Europe/Oslo", "stavanger": "Europe/Oslo",
        "tromsø": "Europe/Oslo", "norway": "Europe/Oslo", "norge": "Europe/Oslo", "new york": "America/New_York",
        "nyc": "America/New_York", "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles",
        "boston": "America/New_York", "washington": "America/New_York", "miami": "America/New_York",
        "austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
        "beijing": "Asia/Shanghai",
        "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "london": "Europe/London", "stockholm": "Europe/Stockholm", "copenhagen": "Europe/Copenhagen",
        "københavn": "Europe/Copenhagen", "helsinki": "Europe/Helsinki", "reykjavik": "Atlantic/Reykjavik",
        "berlin": "Europe/Berlin", "paris": "Europe/Paris", "tokyo": "Asia/Tokyo", "sydney": "Australia/Sydney",
        "melbourne": "Australia/Melbourne", "dubai": "Asia/Dubai", "singapore": "Asia/Singapore",
        "hong kong": "Asia/Hong_Kong", "seoul": "Asia/Seoul", "toronto": "America/Toronto",
        "vancouver": "America/Vancouver", "chicago": "America/Chicago", "denver": "America/Denver",
        "mexico city": "America/Mexico_City", "são paulo": "America/Sao_Paulo", "sao paulo": "America/Sao_Paulo",
        "rio": "America/Sao_Paulo", "buenos aires": "America/Argentina/Buenos_Aires",
        "cape town": "Africa/Johannesburg",
        "johannesburg": "Africa/Johannesburg", "cairo": "Africa/Cairo", "istanbul": "Europe/Istanbul",
        "moscow": "Europe/Moscow", "tel aviv": "Asia/Jerusalem", "bangkok": "Asia/Bangkok", "jakarta": "Asia/Jakarta",
        "manila": "Asia/Manila", "auckland": "Pacific/Auckland", "honolulu": "Pacific/Honolulu",
        "hawaii": "Pacific/Honolulu",
        "amsterdam": "Europe/Amsterdam", "madrid": "Europe/Madrid", "rome": "Europe/Rome", "roma": "Europe/Rome",
        "zurich": "Europe/Zurich", "zürich": "Europe/Zurich", "vienna": "Europe/Vienna", "wien": "Europe/Vienna",
        "warsaw": "Europe/Warsaw", "lisbon": "Europe/Lisbon", "dublin": "Europe/Dublin", "athens": "Europe/Athens",
        "shanghai": "Asia/Shanghai", "taipei": "Asia/Taipei", "kuala lumpur": "Asia/Kuala_Lumpur",
        "utc": "UTC",
    ]

    /// US states, Canadian provinces and countries, each by its main zone.
    private static let regions: [String: String] = [
        // US
        "alabama": "America/Chicago", "alaska": "America/Anchorage", "arizona": "America/Phoenix",
        "arkansas": "America/Chicago", "california": "America/Los_Angeles", "colorado": "America/Denver",
        "connecticut": "America/New_York", "delaware": "America/New_York", "florida": "America/New_York",
        "georgia": "America/New_York", "hawaii": "Pacific/Honolulu", "idaho": "America/Boise",
        "illinois": "America/Chicago", "indiana": "America/Indiana/Indianapolis", "iowa": "America/Chicago",
        "kansas": "America/Chicago", "kentucky": "America/New_York", "louisiana": "America/Chicago",
        "maine": "America/New_York", "maryland": "America/New_York", "massachusetts": "America/New_York",
        "michigan": "America/Detroit", "minnesota": "America/Chicago", "mississippi": "America/Chicago",
        "missouri": "America/Chicago", "montana": "America/Denver", "nebraska": "America/Chicago",
        "nevada": "America/Los_Angeles", "new hampshire": "America/New_York", "new jersey": "America/New_York",
        "new mexico": "America/Denver", "new york state": "America/New_York", "north carolina": "America/New_York",
        "north dakota": "America/Chicago", "ohio": "America/New_York", "oklahoma": "America/Chicago",
        "oregon": "America/Los_Angeles", "pennsylvania": "America/New_York", "rhode island": "America/New_York",
        "south carolina": "America/New_York", "south dakota": "America/Chicago", "tennessee": "America/Chicago",
        "texas": "America/Chicago", "utah": "America/Denver", "vermont": "America/New_York",
        "virginia": "America/New_York", "washington state": "America/Los_Angeles", "west virginia": "America/New_York",
        "wisconsin": "America/Chicago", "wyoming": "America/Denver", "silicon valley": "America/Los_Angeles",
        // Canada
        "ontario": "America/Toronto", "quebec": "America/Toronto", "british columbia": "America/Vancouver",
        "alberta": "America/Edmonton", "manitoba": "America/Winnipeg", "nova scotia": "America/Halifax",
        // Countries
        "sweden": "Europe/Stockholm", "denmark": "Europe/Copenhagen", "finland": "Europe/Helsinki",
        "iceland": "Atlantic/Reykjavik", "uk": "Europe/London", "united kingdom": "Europe/London",
        "england": "Europe/London", "scotland": "Europe/London", "wales": "Europe/London", "ireland": "Europe/Dublin",
        "germany": "Europe/Berlin", "france": "Europe/Paris", "spain": "Europe/Madrid", "portugal": "Europe/Lisbon",
        "italy": "Europe/Rome", "netherlands": "Europe/Amsterdam", "holland": "Europe/Amsterdam",
        "belgium": "Europe/Brussels", "switzerland": "Europe/Zurich", "austria": "Europe/Vienna",
        "poland": "Europe/Warsaw", "czechia": "Europe/Prague", "czech republic": "Europe/Prague",
        "greece": "Europe/Athens", "turkey": "Europe/Istanbul", "ukraine": "Europe/Kyiv", "russia": "Europe/Moscow",
        "estonia": "Europe/Tallinn", "latvia": "Europe/Riga", "lithuania": "Europe/Vilnius",
        "japan": "Asia/Tokyo", "china": "Asia/Shanghai", "south korea": "Asia/Seoul", "korea": "Asia/Seoul",
        "taiwan": "Asia/Taipei", "india": "Asia/Kolkata", "pakistan": "Asia/Karachi", "thailand": "Asia/Bangkok",
        "vietnam": "Asia/Ho_Chi_Minh", "indonesia": "Asia/Jakarta", "philippines": "Asia/Manila",
        "israel": "Asia/Jerusalem", "uae": "Asia/Dubai", "saudi arabia": "Asia/Riyadh", "egypt": "Africa/Cairo",
        "south africa": "Africa/Johannesburg", "nigeria": "Africa/Lagos", "kenya": "Africa/Nairobi",
        "australia": "Australia/Sydney", "new zealand": "Pacific/Auckland", "brazil": "America/Sao_Paulo",
        "argentina": "America/Argentina/Buenos_Aires", "chile": "America/Santiago", "mexico": "America/Mexico_City",
        "canada": "America/Toronto", "usa": "America/New_York", "united states": "America/New_York",
        "east coast": "America/New_York", "west coast": "America/Los_Angeles",
    ]

    private static let cities: [String: String] = {
        var m: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let last = id.split(separator: "/").last else { continue }
            m[last.replacingOccurrences(of: "_", with: " ").lowercased()] = id
        }
        for (k, v) in extraCities { m[k] = v }
        for (k, v) in regions { m[k] = v }
        return m
    }()

    /// Words that name a zone; `word` keeps its case so "PT" (Pacific) differs from "pt" (pint).
    static func lookup(_ word: String) -> Match? {
        let lw = word.lowercased()
        if let z = abbreviations[lw], !capitalsOnly.contains(lw) || word == word.uppercased() {
            return Match(
                zones: z.map {
                    var x = $0
                    x.short = word.uppercased()
                    return x
                }
            )
        }
        if let id = cities[lw], let tz = TimeZone(identifier: id), lw.count >= 3 || extraCities[lw] != nil,
            !commonWords.contains(lw) || regions[lw] != nil
        {
            return Match(zones: [ZoneLit(zone: tz, label: word.capitalized)])
        }
        return nil
    }

    /// City-table words that are far more often something else.
    private static let commonWords: Set<String> = [
        "la", "sf", "rio", "march", "guam", "chile", "eastern", "central", "mountain", "pacific", "east", "general",
        "christmas", "easter", "center", "universal", "zulu", "wake", "midway", "jersey", "casey", "davis", "troll",
        "current", "swift current", "knox", "phoenix", "nome", "chita",
    ]
}
