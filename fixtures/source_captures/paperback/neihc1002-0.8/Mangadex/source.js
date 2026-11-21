(function(f){if(typeof exports==="object"&&typeof module!=="undefined"){module.exports=f()}else if(typeof define==="function"&&define.amd){define([],f)}else{var g;if(typeof window!=="undefined"){g=window}else if(typeof global!=="undefined"){g=global}else if(typeof self!=="undefined"){g=self}else{g=this}g.Sources = f()}})(function(){var define,module,exports;return (function(){function r(e,n,t){function o(i,f){if(!n[i]){if(!e[i]){var c="function"==typeof require&&require;if(!f&&c)return c(i,!0);if(u)return u(i,!0);var a=new Error("Cannot find module '"+i+"'");throw a.code="MODULE_NOT_FOUND",a}var p=n[i]={exports:{}};e[i][0].call(p.exports,function(r){var n=e[i][1][r];return o(n||r)},p,p.exports,r,e,n,t)}return n[i].exports}for(var u="function"==typeof require&&require,i=0;i<t.length;i++)o(t[i]);return o}return r})()({1:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.BadgeColor = void 0;
var BadgeColor;
(function (BadgeColor) {
    BadgeColor["BLUE"] = "default";
    BadgeColor["GREEN"] = "success";
    BadgeColor["GREY"] = "info";
    BadgeColor["YELLOW"] = "warning";
    BadgeColor["RED"] = "danger";
})(BadgeColor = exports.BadgeColor || (exports.BadgeColor = {}));

},{}],2:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],3:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.HomeSectionType = void 0;
var HomeSectionType;
(function (HomeSectionType) {
    HomeSectionType["singleRowNormal"] = "singleRowNormal";
    HomeSectionType["singleRowLarge"] = "singleRowLarge";
    HomeSectionType["doubleRow"] = "doubleRow";
    HomeSectionType["featured"] = "featured";
})(HomeSectionType = exports.HomeSectionType || (exports.HomeSectionType = {}));

},{}],4:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],5:[function(require,module,exports){
"use strict";
/**
 * Request objects hold information for a particular source (see sources for example)
 * This allows us to to use a generic api to make the calls against any source
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.urlEncodeObject = exports.convertTime = exports.Source = void 0;
/**
* @deprecated Use {@link PaperbackExtensionBase}
*/
class Source {
    constructor(cheerio) {
        this.cheerio = cheerio;
    }
    /**
     * @deprecated use {@link Source.getSearchResults getSearchResults} instead
     */
    searchRequest(query, metadata) {
        return this.getSearchResults(query, metadata);
    }
    /**
     * @deprecated use {@link Source.getSearchTags} instead
     */
    async getTags() {
        // @ts-ignore
        return this.getSearchTags?.();
    }
}
exports.Source = Source;
// Many sites use '[x] time ago' - Figured it would be good to handle these cases in general
function convertTime(timeAgo) {
    let time;
    let trimmed = Number((/\d*/.exec(timeAgo) ?? [])[0]);
    trimmed = (trimmed == 0 && timeAgo.includes('a')) ? 1 : trimmed;
    if (timeAgo.includes('minutes')) {
        time = new Date(Date.now() - trimmed * 60000);
    }
    else if (timeAgo.includes('hours')) {
        time = new Date(Date.now() - trimmed * 3600000);
    }
    else if (timeAgo.includes('days')) {
        time = new Date(Date.now() - trimmed * 86400000);
    }
    else if (timeAgo.includes('year') || timeAgo.includes('years')) {
        time = new Date(Date.now() - trimmed * 31556952000);
    }
    else {
        time = new Date(Date.now());
    }
    return time;
}
exports.convertTime = convertTime;
/**
 * When a function requires a POST body, it always should be defined as a JsonObject
 * and then passed through this function to ensure that it's encoded properly.
 * @param obj
 */
function urlEncodeObject(obj) {
    let ret = {};
    for (const entry of Object.entries(obj)) {
        ret[encodeURIComponent(entry[0])] = encodeURIComponent(entry[1]);
    }
    return ret;
}
exports.urlEncodeObject = urlEncodeObject;

},{}],6:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ContentRating = exports.SourceIntents = void 0;
var SourceIntents;
(function (SourceIntents) {
    SourceIntents[SourceIntents["MANGA_CHAPTERS"] = 1] = "MANGA_CHAPTERS";
    SourceIntents[SourceIntents["MANGA_TRACKING"] = 2] = "MANGA_TRACKING";
    SourceIntents[SourceIntents["HOMEPAGE_SECTIONS"] = 4] = "HOMEPAGE_SECTIONS";
    SourceIntents[SourceIntents["COLLECTION_MANAGEMENT"] = 8] = "COLLECTION_MANAGEMENT";
    SourceIntents[SourceIntents["CLOUDFLARE_BYPASS_REQUIRED"] = 16] = "CLOUDFLARE_BYPASS_REQUIRED";
    SourceIntents[SourceIntents["SETTINGS_UI"] = 32] = "SETTINGS_UI";
})(SourceIntents = exports.SourceIntents || (exports.SourceIntents = {}));
/**
 * A content rating to be attributed to each source.
 */
var ContentRating;
(function (ContentRating) {
    ContentRating["EVERYONE"] = "EVERYONE";
    ContentRating["MATURE"] = "MATURE";
    ContentRating["ADULT"] = "ADULT";
})(ContentRating = exports.ContentRating || (exports.ContentRating = {}));

},{}],7:[function(require,module,exports){
"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __exportStar = (this && this.__exportStar) || function(m, exports) {
    for (var p in m) if (p !== "default" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);
};
Object.defineProperty(exports, "__esModule", { value: true });
__exportStar(require("./Source"), exports);
__exportStar(require("./ByteArray"), exports);
__exportStar(require("./Badge"), exports);
__exportStar(require("./interfaces"), exports);
__exportStar(require("./SourceInfo"), exports);
__exportStar(require("./HomeSectionType"), exports);
__exportStar(require("./PaperbackExtensionBase"), exports);

},{"./Badge":1,"./ByteArray":2,"./HomeSectionType":3,"./PaperbackExtensionBase":4,"./Source":5,"./SourceInfo":6,"./interfaces":15}],8:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],9:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],10:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],11:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],12:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],13:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],14:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],15:[function(require,module,exports){
"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __exportStar = (this && this.__exportStar) || function(m, exports) {
    for (var p in m) if (p !== "default" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);
};
Object.defineProperty(exports, "__esModule", { value: true });
__exportStar(require("./ChapterProviding"), exports);
__exportStar(require("./CloudflareBypassRequestProviding"), exports);
__exportStar(require("./HomePageSectionsProviding"), exports);
__exportStar(require("./MangaProgressProviding"), exports);
__exportStar(require("./MangaProviding"), exports);
__exportStar(require("./RequestManagerProviding"), exports);
__exportStar(require("./SearchResultsProviding"), exports);

},{"./ChapterProviding":8,"./CloudflareBypassRequestProviding":9,"./HomePageSectionsProviding":10,"./MangaProgressProviding":11,"./MangaProviding":12,"./RequestManagerProviding":13,"./SearchResultsProviding":14}],16:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],17:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],18:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],19:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],20:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],21:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],22:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],23:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],24:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],25:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],26:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],27:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],28:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],29:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],30:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],31:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],32:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],33:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],34:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],35:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],36:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],37:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],38:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],39:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],40:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],41:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],42:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],43:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],44:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],45:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],46:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],47:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],48:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],49:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],50:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],51:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],52:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],53:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],54:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],55:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],56:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],57:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],58:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],59:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });

},{}],60:[function(require,module,exports){
"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __exportStar = (this && this.__exportStar) || function(m, exports) {
    for (var p in m) if (p !== "default" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);
};
Object.defineProperty(exports, "__esModule", { value: true });
__exportStar(require("./DynamicUI/Exports/DUIBinding"), exports);
__exportStar(require("./DynamicUI/Exports/DUIForm"), exports);
__exportStar(require("./DynamicUI/Exports/DUIFormRow"), exports);
__exportStar(require("./DynamicUI/Exports/DUISection"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUIButton"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUIHeader"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUIInputField"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUILabel"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUILink"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUIMultilineLabel"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUINavigationButton"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUIOAuthButton"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUISecureInputField"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUISelect"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUIStepper"), exports);
__exportStar(require("./DynamicUI/Rows/Exports/DUISwitch"), exports);
__exportStar(require("./Exports/ChapterDetails"), exports);
__exportStar(require("./Exports/Chapter"), exports);
__exportStar(require("./Exports/Cookie"), exports);
__exportStar(require("./Exports/HomeSection"), exports);
__exportStar(require("./Exports/IconText"), exports);
__exportStar(require("./Exports/MangaInfo"), exports);
__exportStar(require("./Exports/MangaProgress"), exports);
__exportStar(require("./Exports/PartialSourceManga"), exports);
__exportStar(require("./Exports/MangaUpdates"), exports);
__exportStar(require("./Exports/PBCanvas"), exports);
__exportStar(require("./Exports/PBImage"), exports);
__exportStar(require("./Exports/PagedResults"), exports);
__exportStar(require("./Exports/RawData"), exports);
__exportStar(require("./Exports/Request"), exports);
__exportStar(require("./Exports/SourceInterceptor"), exports);
__exportStar(require("./Exports/RequestManager"), exports);
__exportStar(require("./Exports/Response"), exports);
__exportStar(require("./Exports/SearchField"), exports);
__exportStar(require("./Exports/SearchRequest"), exports);
__exportStar(require("./Exports/SourceCookieStore"), exports);
__exportStar(require("./Exports/SourceManga"), exports);
__exportStar(require("./Exports/SecureStateManager"), exports);
__exportStar(require("./Exports/SourceStateManager"), exports);
__exportStar(require("./Exports/Tag"), exports);
__exportStar(require("./Exports/TagSection"), exports);
__exportStar(require("./Exports/TrackedMangaChapterReadAction"), exports);
__exportStar(require("./Exports/TrackerActionQueue"), exports);

},{"./DynamicUI/Exports/DUIBinding":17,"./DynamicUI/Exports/DUIForm":18,"./DynamicUI/Exports/DUIFormRow":19,"./DynamicUI/Exports/DUISection":20,"./DynamicUI/Rows/Exports/DUIButton":21,"./DynamicUI/Rows/Exports/DUIHeader":22,"./DynamicUI/Rows/Exports/DUIInputField":23,"./DynamicUI/Rows/Exports/DUILabel":24,"./DynamicUI/Rows/Exports/DUILink":25,"./DynamicUI/Rows/Exports/DUIMultilineLabel":26,"./DynamicUI/Rows/Exports/DUINavigationButton":27,"./DynamicUI/Rows/Exports/DUIOAuthButton":28,"./DynamicUI/Rows/Exports/DUISecureInputField":29,"./DynamicUI/Rows/Exports/DUISelect":30,"./DynamicUI/Rows/Exports/DUIStepper":31,"./DynamicUI/Rows/Exports/DUISwitch":32,"./Exports/Chapter":33,"./Exports/ChapterDetails":34,"./Exports/Cookie":35,"./Exports/HomeSection":36,"./Exports/IconText":37,"./Exports/MangaInfo":38,"./Exports/MangaProgress":39,"./Exports/MangaUpdates":40,"./Exports/PBCanvas":41,"./Exports/PBImage":42,"./Exports/PagedResults":43,"./Exports/PartialSourceManga":44,"./Exports/RawData":45,"./Exports/Request":46,"./Exports/RequestManager":47,"./Exports/Response":48,"./Exports/SearchField":49,"./Exports/SearchRequest":50,"./Exports/SecureStateManager":51,"./Exports/SourceCookieStore":52,"./Exports/SourceInterceptor":53,"./Exports/SourceManga":54,"./Exports/SourceStateManager":55,"./Exports/Tag":56,"./Exports/TagSection":57,"./Exports/TrackedMangaChapterReadAction":58,"./Exports/TrackerActionQueue":59}],61:[function(require,module,exports){
"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __exportStar = (this && this.__exportStar) || function(m, exports) {
    for (var p in m) if (p !== "default" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);
};
Object.defineProperty(exports, "__esModule", { value: true });
__exportStar(require("./generated/_exports"), exports);
__exportStar(require("./base/index"), exports);
__exportStar(require("./compat/DyamicUI"), exports);

},{"./base/index":7,"./compat/DyamicUI":16,"./generated/_exports":60}],62:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.setStateData = exports.retrieveStateData = exports.DEFAULT_API = exports.DEFAULT_LANGUAGE = void 0;
exports.DEFAULT_LANGUAGE = 'vi';
exports.DEFAULT_API = 'https://api.mangadex.org';
async function retrieveStateData(stateManager) {
    const apiURL = await stateManager.retrieve('apiURL') ?? exports.DEFAULT_API;
    const language = await stateManager.keychain.retrieve('language') ?? exports.DEFAULT_LANGUAGE;
    return { apiURL, language };
}
exports.retrieveStateData = retrieveStateData;
async function setStateData(stateManager, data) {
    await stateManager.keychain.store('apiURL', data['apiURL'] ?? exports.DEFAULT_API);
    await stateManager.keychain.store('language', data['language'] ?? exports.DEFAULT_LANGUAGE);
}
exports.setStateData = setStateData;

},{}],63:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.Mangadex = exports.MangadexInfo = void 0;
const types_1 = require("@paperback/types");
const parser_1 = require("./parser");
const Settings_1 = require("./Settings");
const Common_1 = require("./Common");
const DOMAIN = "https://mangadex.org";
const API_URL = DOMAIN.replace("https://", "https://api.");
exports.MangadexInfo = {
    version: "1.0.0",
    name: "Mangadex",
    icon: "icon.png",
    author: "neihc1002",
    authorWebsite: "https://github.com/neich1002",
    description: "Extension that pulls manga from Mangadex",
    contentRating: types_1.ContentRating.MATURE,
    websiteBaseURL: DOMAIN,
    sourceTags: [
        {
            text: "Recommended",
            type: types_1.BadgeColor.BLUE,
        },
    ],
    intents: types_1.SourceIntents.MANGA_CHAPTERS |
        types_1.SourceIntents.HOMEPAGE_SECTIONS |
        types_1.SourceIntents.SETTINGS_UI,
};
class Mangadex extends types_1.Source {
    constructor() {
        super(...arguments);
        this.parser = new parser_1.Parser();
        this.stateManager = App.createSourceStateManager();
        this.requestManager = App.createRequestManager({
            requestsPerSecond: 4,
            requestTimeout: 20000,
            interceptor: {
                interceptRequest: async (request) => {
                    request.headers = {
                        ...(request.headers ?? {}),
                        ...{
                            referer: DOMAIN,
                            "user-agent": await this.requestManager.getDefaultUserAgent(),
                        },
                    };
                    return request;
                },
                interceptResponse: async (response) => {
                    return response;
                },
            },
        });
    }
    async queryApi(url, queries) {
        const params = Object.entries(queries)
            .map(([key, value]) => {
            if (Array.isArray(value)) {
                const arrayKey = key.endsWith("[]") ? key.slice(0, -2) : key;
                return value
                    .map((v) => `${arrayKey}[]=${encodeURIComponent(String(v))}`)
                    .join("&");
            }
            return `${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`;
        })
            .join("&");
        const options = await (0, Common_1.retrieveStateData)(this.stateManager);
        const request = App.createRequest({
            url: `${options.apiURL}/${url}?${params}`,
            method: "GET",
        });
        const response = await this.requestManager.schedule(request, 1);
        return JSON.parse(response.data);
    }
    async queryApiList(queries, page = 0) {
        const result = (await this.queryApi("manga", {
            ...queries,
            offset: page,
        }));
        return result;
    }
    async queryDetails(bookId) {
        const result = (await this.queryApi(`manga/${bookId}`, {
            "includes[]": ["artist", "author", "cover_art"],
        }));
        return result;
    }
    async queryChapterList(bookid, limit, page = 0) {
        const options = await (0, Common_1.retrieveStateData)(this.stateManager);
        const result = (await this.queryApi(`manga/${bookid}/feed`, {
            offset: page,
            limit,
            "order[volume]": "asc",
            "order[chapter]": "asc",
            "translatedLanguage[]": options.language,
        }));
        return result;
    }
    async queryChapterDetail(chapterId) {
        const result = (await this.queryApi(`at-home/server/${chapterId}`, {
            forcePort443: "false",
        }));
        return result;
    }
    async getMangaDetails(mangaId) {
        const response = await this.queryDetails(mangaId);
        const options = await (0, Common_1.retrieveStateData)(this.stateManager);
        return this.parser.parseMangaInfoDetails(response.data, options.language);
    }
    async getChapters(mangaId) {
        let chapterData = [];
        const firstLoadResponse = await this.queryChapterList(mangaId, 500, 0);
        chapterData.push(...firstLoadResponse.data);
        while (chapterData.length < firstLoadResponse.total) {
            const nextResponse = await this.queryChapterList(mangaId, 500, chapterData.length);
            chapterData.push(...nextResponse.data);
        }
        return this.parser.parseChapters(chapterData);
    }
    async getChapterDetails(mangaId, chapterId) {
        const response = await this.queryChapterDetail(chapterId);
        const pages = this.parser.parseChapterDetails(response);
        return App.createChapterDetails({
            id: chapterId,
            mangaId: mangaId,
            pages: pages,
        });
    }
    async getSearchResults(query, metadata) {
        let page = metadata?.page ?? 0;
        const options = await (0, Common_1.retrieveStateData)(this.stateManager);
        let search = {
            "includes[]": "cover_art",
            "contentRating[]": "suggestive",
            "availableTranslatedLanguage[]": options.language,
            hasAvailableChapters: "true",
        };
        if (query.includedTags) {
            const tags = query.includedTags?.map((tag) => tag.id) ?? [];
            if (tags.length > 0) {
                search = { ...search, "includedTags[]": tags };
            }
        }
        if (query.title) {
            search = { ...search, title: query.title };
        }
        const response = await this.queryApiList(search, page);
        const tiles = this.parser.parseMangaInfo(response.data, options.language);
        metadata =
            page < response.total ? { page: page + response.data.length } : undefined;
        return App.createPagedResults({
            results: tiles,
            metadata,
        });
    }
    async getHomePageSections(sectionCallback) {
        console.log("DocTruyen3Q Running...");
        const sections = [
            App.createHomeSection({
                id: "featured",
                title: "TRUYỆN PHỔ BIẾN",
                containsMoreItems: true,
                type: types_1.HomeSectionType.singleRowNormal,
            }),
            App.createHomeSection({
                id: "new_updated",
                title: "TRUYỆN MỚI CẬP NHẬT",
                containsMoreItems: true,
                type: types_1.HomeSectionType.singleRowNormal,
            }),
        ];
        const options = await (0, Common_1.retrieveStateData)(this.stateManager);
        const baseQuery = {
            "includes[]": "cover_art",
            includedTagsMode: "AND",
            excludedTagsMode: "OR",
            "availableTranslatedLanguage[]": options.language,
        };
        let response;
        for (const section of sections) {
            switch (section.id) {
                case "featured":
                    response = await this.queryApiList({
                        ...baseQuery,
                        "order[rating]": "desc",
                    });
                    section.items = this.parser.parseMangaInfo(response.data, options.language);
                    break;
                case "new_updated":
                    response = await this.queryApiList({
                        ...baseQuery,
                        "order[latestUploadedChapter]": "desc",
                    });
                    section.items = this.parser.parseMangaInfo(response.data, options.language);
                    break;
            }
            sectionCallback(section);
        }
        //throw new Error("No items found");
    }
    async getViewMoreItems(homepageSectionId, metadata) {
        let page = metadata?.page ?? 0;
        const options = await (0, Common_1.retrieveStateData)(this.stateManager);
        const baseQuery = {
            "includes[]": "cover_art",
            includedTagsMode: "AND",
            excludedTagsMode: "OR",
            "availableTranslatedLanguage[]": options.language,
        };
        let query;
        switch (homepageSectionId) {
            case "featured":
                query = {
                    ...baseQuery,
                    "order[rating]": "desc",
                };
                break;
            case "new_updated":
                query = {
                    ...baseQuery,
                    "order[latestUploadedChapter]": "desc",
                };
                break;
            default:
                throw new Error("Requested to getViewMoreItems for a section ID which doesn't exist");
        }
        const response = await this.queryApiList(query, page);
        let manga = this.parser.parseMangaInfo(response.data, options.language);
        metadata =
            page < response.total ? { page: page + response.data.length } : undefined;
        return App.createPagedResults({
            results: manga,
            metadata,
        });
    }
    getMangaShareUrl(mangaId) {
        return `${DOMAIN}truyen-tranh/${mangaId}`;
    }
    async getSearchTags() {
        const response = (await this.queryApi("manga/tag", {}));
        const tags = response.data.map((x) => App.createTag({
            id: x.id,
            label: x.attributes?.name?.en || ''
        }));
        const tagSections = [
            App.createTagSection({ id: "0", label: "Thể loại", tags: tags }),
        ];
        return Promise.resolve(tagSections);
    }
    async getSourceMenu() {
        return App.createDUISection({
            id: 'main',
            header: 'Source Settings',
            isHidden: false,
            rows: async () => [
                (0, Settings_1.serverSettingsMenu)(this.stateManager),
            ]
        });
    }
}
exports.Mangadex = Mangadex;

},{"./Common":62,"./Settings":64,"./parser":65,"@paperback/types":61}],64:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.serverSettingsMenu = exports.getDefaultStatus = void 0;
const Common_1 = require("./Common");
const getDefaultStatus = async (stateManager) => {
    return await stateManager.retrieve('language') ?? ['NONE'];
};
exports.getDefaultStatus = getDefaultStatus;
const serverSettingsMenu = (stateManager) => {
    return App.createDUINavigationButton({
        id: 'server_settings',
        label: 'Mangadex Settings',
        form: App.createDUIForm({
            sections: async () => {
                const values = await (0, Common_1.retrieveStateData)(stateManager);
                return [
                    App.createDUISection({
                        id: 'setting',
                        isHidden: false,
                        rows: async () => [
                            App.createDUISelect({
                                id: 'language',
                                label: 'Language',
                                allowsMultiselect: false,
                                value: App.createDUIBinding({
                                    get: async () => [values.language],
                                    set: async (newValue) => {
                                        // throw new Error(newValue)
                                        values.language = newValue[0];
                                        await (0, Common_1.setStateData)(stateManager, values);
                                    }
                                }),
                                labelResolver: async (value) => {
                                    switch (value) {
                                        case 'vi': return 'Vietnamese';
                                        case 'en': return 'English';
                                        default: return 'None';
                                    }
                                },
                                options: [
                                    'vi',
                                    'en'
                                ]
                            }),
                            App.createDUIInputField({
                                id: 'serverAddress',
                                label: 'Server URL',
                                value: App.createDUIBinding({
                                    async get() {
                                        return values.apiURL;
                                    },
                                    async set(newValue) {
                                        values.apiURL = newValue;
                                        await (0, Common_1.setStateData)(stateManager, values);
                                    }
                                })
                            }),
                        ],
                    }),
                ];
            }
        })
    });
};
exports.serverSettingsMenu = serverSettingsMenu;

},{"./Common":62}],65:[function(require,module,exports){
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.Parser = void 0;
const DOMAIN = "https://mangadex.org";
class Parser {
    parseMangaInfo(list, language) {
        return list.map((mg) => {
            let bookId = mg.id;
            let cover = mg.relationships.find((item) => item.type === "cover_art");
            let image = "";
            if (cover) {
                image =
                    DOMAIN +
                        "/covers/" +
                        bookId +
                        "/" +
                        cover.attributes?.fileName +
                        ".256.jpg";
            }
            const title = (mg.attributes?.altTitles?.find((x) => x[language])?.[language] || mg.attributes?.title?.en || "");
            return App.createPartialSourceManga({
                mangaId: mg.id,
                image,
                title,
                // subtitle,
            });
        });
    }
    parseMangaInfoDetails(details, language) {
        let authors = details.relationships.filter((item) => item.type === "author");
        let author = "";
        if (author) {
            author = authors.map((au) => au?.attributes?.name ?? "").join(", ");
        }
        const title = (details.attributes?.altTitles?.find((x) => x[language])?.[language] || details.attributes?.title?.en || "");
        let cover = details.relationships.find((item) => item.type === "cover_art");
        let image = "";
        if (cover) {
            image =
                DOMAIN +
                    "/covers/" +
                    details.id +
                    "/" +
                    cover.attributes?.fileName +
                    ".512.jpg";
        }
        const desc = details.attributes.description[language] ?? details.attributes.description['en'] ?? '';
        const tag = App.createTagSection({
            id: "0",
            label: "Thể loại",
            tags: details.attributes.tags.map((x) => App.createTag({
                id: x.id,
                label: x.attributes.name[language] ?? x.attributes.name['en'] ?? '',
            })),
        });
        return App.createSourceManga({
            id: details.id,
            mangaInfo: App.createMangaInfo({
                titles: [title],
                image,
                desc,
                status: this.getStatus(details.attributes.status),
                author,
                tags: [tag]
            }),
        });
    }
    getStatus(status) {
        switch (status) {
            case "ongoing":
                return "Chưa hoàn thành";
            case "completed":
                return "Hoàn thành";
            default:
                return "";
        }
    }
    parseChapters(data) {
        const result = data.map((chapter) => {
            return App.createChapter({
                id: chapter.id,
                chapNum: parseFloat(chapter.attributes.chapter),
                name: chapter.attributes.title,
                langCode: "🇻🇳",
                time: new Date(chapter.attributes.readableAt),
                volume: chapter.attributes.volume &&
                    chapter.attributes.volume.trim().length > 0
                    ? parseFloat(chapter.attributes.volume)
                    : undefined
                //group: `${group} lượt xem`,
            });
        });
        return result;
    }
    parseChapterDetails(detail) {
        const pages = detail.chapter.data.map((x) => {
            const image = detail.baseUrl + "/data/" + detail.chapter.hash + "/" + x;
            return image;
        });
        return pages;
    }
}
exports.Parser = Parser;

},{}]},{},[63])(63)
});
