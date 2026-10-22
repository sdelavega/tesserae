#!/usr/bin/env python3
# Tesserae: a disk-space visualizer.
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Create a curated personal disk. Run with python3 -I.

Example dry run (only the manifest is written):
  python3 -I scripts/make-demo-volume.py --target /tmp/demo --volume-uuid \
    12345678-1234-1234-1234-123456789ABC --dry-run --manifest apple/build/demo-manifest.tsv

--bytes scales the same collection for smaller/larger volumes; media sizes are
life-sized at the default 18 GiB. Dates use a fixed editorial snapshot rather
than the wall clock. Existing files are skipped only on size/mtime agreement;
conflicts stop the run. File contents are never overwritten or deleted;
provenance-only AppleDouble sidecars are cleaned up.
"""

import argparse
import csv
import ctypes
import errno
import datetime as dt
import os
from pathlib import Path, PurePosixPath
import plistlib
import random
import shutil
import stat
import subprocess
import sys
from typing import NamedTuple
import uuid

MIB = 1024**2
DEFAULT_BYTES = 18 * 1024**3


class Entry(NamedTuple):
    path: PurePosixPath
    size: int
    mtime: int
    text: bytes


def timestamp(value):
    return int(dt.datetime.fromisoformat(value).replace(tzinfo=dt.timezone.utc).timestamp())


def text_for(path):
    name = path.name
    notes = {
        'Lemon and thyme chicken.md': '# Lemon and thyme chicken\n\nRoast with potatoes, lemon wedges and thyme at 200 C for 45 minutes.\n',
        'Sunday focaccia.txt': '500 g flour, 400 g water, 10 g salt, 3 g yeast.\nFold twice, chill overnight, dimple with olive oil and bake until golden.\n',
        'Moving checklist.md': '# Moving checklist\n\n- Return spare keys\n- Photograph meter readings\n- Book the van for Saturday morning\n',
        'Reading notes.md': '# Reading notes\n\nThe coastal interviews connect everyday routes with memories of place.\nRevisit the chapter on seasonal migration before revising the introduction.\n',
        'Weekend errands.txt': 'Pick up bicycle, buy potting soil, return library books.\nMeet Maya at the cafe after lunch.\n',
        'Read me first.txt': 'Personal working disk.\nCurrent work is in Projects; older material is in Archive.\n',
        'Places to visit.md': '# Places to visit\n\nLisbon botanical garden\nThe lake trail in autumn\nCoastal railway museum\n',
    }
    if name in notes:
        return notes[name].encode()
    if str(path).endswith('.git/HEAD'):
        return b'ref: refs/heads/main\n'
    if str(path).endswith('.git/config'):
        return b'[core]\n    repositoryformatversion = 0\n    bare = false\n'
    if name == 'pyproject.toml':
        return b'[project]\nname = "pantry-planner"\nversion = "0.3.0"\nrequires-python = ">=3.11"\n'
    if path.suffix == '.pbxproj':
        return b'// !$*UTF8*$!\n{ archiveVersion = 1; objectVersion = 56; objects = {}; }\n'
    if name == 'README.md' and 'node_modules' not in path.parts:
        return ('# ' + path.parts[1].replace('-', ' ').title() + '\n\nA personal tool for keeping local notes organized.\nRun the test suite before changing the import format.\n').encode()
    if name == 'package.json':
        package = path.parent.name
        return ('{"name":"' + package + '","version":"1.0.0"}\n').encode()
    if path.suffix in ('.json', '.map'):
        return b'{"theme":"system","recentFolders":[],"autosave":true}\n'
    if path.suffix == '.csv':
        return b'date,description,amount\n2025-03-14,Workshop supplies,48.50\n'
    if path.suffix == '.rs':
        return b'pub fn normalize_label(label: &str) -> String {\n    label.trim().to_lowercase()\n}\n'
    if path.suffix in ('.ts', '.js'):
        return b'export function displayName(value) {\n  return value.trim() || "Untitled";\n}\n'
    if path.suffix == '.py':
        return b'"""Helpers for the local catalog."""\n\ndef normalize(value):\n    return value.strip().lower()\n'
    if name == 'Cargo.toml':
        return b'[package]\nname = "trail-notes"\nversion = "0.2.0"\nedition = "2021"\n'
    if path.suffix == '.xmp':
        return b'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rating>3</rating></x:xmpmeta>\n'
    if path.suffix in ('.md', '.txt', '.html', '.css', '.toml', '.yml', '.yaml', '.lock', '.swift', '.pbxproj', '.sh', '.h', '.c', '.metal', '.plist', '.xcconfig', '.xml', '.modulemap') or name in ('HEAD', 'config', 'LICENSE', 'justfile', '.gitignore'):
        if path.suffix == '.swift':
            return b'import Foundation\nstruct Note { var title: String; var body: String }\n'
        if path.suffix == '.html':
            return b'<!doctype html><title>Field journal</title><main>Saved places</main>\n'
        if path.suffix == '.css':
            return b'body { font-family: system-ui; margin: 2rem; color: #243832; }\n'
        return ('# ' + path.stem.replace('-', ' ').title() + '\n\nLocal notes and working material.\nReview the saved draft before sharing.\n').encode()
    return b''


TESSERAE_SNAPSHOT = Path(__file__).resolve().parent / 'demo/tesserae-tree.tsv'


def tesserae_entries():
    entries = []
    with TESSERAE_SNAPSHOT.open(newline='', encoding='utf-8') as stream:
        for row in csv.DictReader(stream, delimiter='\t'):
            path = PurePosixPath(row['path'])
            if (path.is_absolute() or '..' in path.parts or not path.parts
                    or '.git' in path.parts or str(Path.home()) in str(path)):
                raise ValueError('unsafe Tesserae snapshot path')
            size = int(row['bytes'])
            when = int(dt.datetime.fromisoformat(row['mtime']).timestamp())
            if size < 0:
                raise ValueError('negative Tesserae snapshot size')
            # Only metadata comes from the snapshot. Small files truncate the
            # placeholder; binary extensions receive zero bytes from write_tree.
            text = text_for(PurePosixPath('Projects/tesserae') / path)
            if text:
                text = b'# Tesserae synthetic demo placeholder.\n' + text
            entries.append(Entry(PurePosixPath('Projects/tesserae') / path,
                                 size, when, text[:size]))
    if not entries:
        raise ValueError('empty Tesserae snapshot')
    return entries


# The snapshot is intentionally independent of the clock on the writing machine.
NOW = timestamp('2026-10-21T12:00:00')
NPM_MTIME = timestamp('1985-10-26T08:15:00')


def package_layouts():
    """Small editorial layouts, following each package's published directory shape.

    Large API families expand real export names across their shipped build formats;
    they never borrow the personal projects' module vocabulary.
    """
    layouts = {}

    def store(package, files):
        layouts[package] = sorted(set(['package.json', 'README.md', 'LICENSE'] + list(files)))

    lodash = '''add after ary assign assignIn assignInWith assignWith at attempt before bind bindAll bindKey camelCase capitalize castArray ceil chain chunk clamp clone cloneDeep cloneDeepWith cloneWith compact concat cond conforms conformsTo constant countBy create curry curryRight debounce deburr defaultTo defaults defaultsDeep defer delay difference differenceBy differenceWith divide drop dropRight dropRightWhile dropWhile each eachRight endsWith eq escape escapeRegExp every extend extendWith fill filter find findIndex findKey findLast findLastIndex findLastKey first flatMap flatMapDeep flatMapDepth flatten flattenDeep flattenDepth flip floor flow flowRight forEach forEachRight forIn forInRight forOwn forOwnRight fromPairs functions functionsIn get groupBy gt gte has hasIn head identity includes indexOf initial intersection intersectionBy intersectionWith invert invertBy invoke invokeMap isArguments isArray isArrayBuffer isArrayLike isArrayLikeObject isBoolean isBuffer isDate isElement isEmpty isEqual isEqualWith isError isFinite isFunction isInteger isLength isMap isMatch isMatchWith isNaN isNative isNil isNull isNumber isObject isObjectLike isPlainObject isRegExp isSafeInteger isSet isString isSymbol isTypedArray isUndefined isWeakMap isWeakSet iteratee join kebabCase keyBy keys keysIn last lastIndexOf lowerCase lowerFirst lt lte map mapKeys mapValues matches matchesProperty max maxBy mean meanBy memoize merge mergeWith method methodOf min minBy mixin multiply negate noop now nth nthArg omit omitBy once orderBy over overArgs overEvery overSome pad padEnd padStart parseInt partial partialRight partition pick pickBy property propertyOf pull pullAll pullAllBy pullAllWith pullAt random range rangeRight rearg reduce reduceRight reject remove repeat replace rest result reverse round sample sampleSize set setWith shuffle size slice snakeCase some sortBy sortedIndex sortedIndexBy sortedIndexOf sortedLastIndex sortedLastIndexBy sortedLastIndexOf sortedUniq sortedUniqBy split spread startCase startsWith stubArray stubFalse stubObject stubString stubTrue subtract sum sumBy tail take takeRight takeRightWhile takeWhile tap template throttle thru times toArray toFinite toInteger toLength toLower toNumber toPairs toPairsIn toPath toPlainObject toSafeInteger toString toUpper transform trim trimEnd trimStart truncate unary unescape union unionBy unionWith uniq uniqBy uniqueId uniqWith unset unzip unzipWith update updateWith upperCase upperFirst values valuesIn without words wrap xor xorBy xorWith zip zipObject zipObjectDeep zipWith'''.split()
    internals = '''Hash ListCache MapCache SetCache Stack Symbol Uint8Array apply arrayAggregator arrayEach arrayEachRight arrayEvery arrayFilter arrayIncludes arrayIncludesWith arrayMap arrayPush arrayReduce arrayReduceRight arraySample arraySampleSize arrayShuffle arraySome asciiSize asciiToArray asciiWords assignValue assocIndexOf baseAssign baseAssignIn baseAssignValue baseAt baseClamp baseClone baseCompareAscending baseConforms baseConformsTo baseCreate baseDelay baseDifference baseEach baseEachRight baseEvery baseExtremum baseFill baseFilter baseFindIndex baseFindKey baseFlatten baseFor baseForOwn baseGet baseGetAllKeys baseGetTag baseHas baseHasIn baseIndexOf baseIntersection baseIsEqual baseIsMatch baseIteratee baseKeys baseKeysIn baseMap baseMatches baseMatchesProperty baseMerge baseOrderBy basePick basePickBy baseProperty basePullAll baseRandom baseRange baseReduce baseRepeat baseRest baseSet baseSlice baseSortBy baseSum baseToString baseUniq baseUnset baseUpdate baseValues cacheHas castPath castSlice cloneArrayBuffer cloneBuffer cloneDataView cloneRegExp cloneSymbol cloneTypedArray compareAscending composeArgs copyArray copyObject createAggregator createAssigner createBaseEach createBaseFor createBind createCaseFirst createCompounder createCurry createHybrid createPartial createRange createRecurry createRelationalOperation createRound createWrap equalArrays equalByTag equalObjects freeGlobal getAllKeys getAllKeysIn getMapData getMatchData getNative getPrototype getRawTag getSymbols getTag getValue hasOwnProperty identity initCloneArray initCloneByTag initCloneObject isFlattenable isIndex isKey isKeyable isMasked isPrototype mapToArray memoizeCapped nativeCreate nativeKeys objectToString overArg parent root setToArray shortOut shuffleSelf stackClear stackDelete stackGet stackHas stackSet stringToArray stringToPath toKey unicodeSize unicodeToArray unicodeWords'''.split()
    store('lodash', [f'{n}.js' for n in lodash] + [f'_{n}.js' for n in internals] +
          [f'fp/{n}.js' for n in lodash] + ['lodash.js', 'lodash.min.js', 'fp/_baseConvert.js', 'fp/_mapping.js'])
    datefns = '''add addBusinessDays addDays addHours addISOWeekYears addMilliseconds addMinutes addMonths addQuarters addSeconds addWeeks addYears areIntervalsOverlapping clamp closestIndexTo closestTo compareAsc compareDesc daysToWeeks differenceInBusinessDays differenceInCalendarDays differenceInCalendarISOWeekYears differenceInCalendarISOWeeks differenceInCalendarMonths differenceInCalendarQuarters differenceInCalendarWeeks differenceInCalendarYears differenceInDays differenceInHours differenceInISOWeekYears differenceInMilliseconds differenceInMinutes differenceInMonths differenceInQuarters differenceInSeconds differenceInWeeks differenceInYears eachDayOfInterval eachHourOfInterval eachMinuteOfInterval eachMonthOfInterval eachQuarterOfInterval eachWeekendOfInterval eachWeekendOfMonth eachWeekendOfYear eachWeekOfInterval eachYearOfInterval endOfDay endOfDecade endOfHour endOfISOWeek endOfISOWeekYear endOfMinute endOfMonth endOfQuarter endOfSecond endOfToday endOfTomorrow endOfWeek endOfYear endOfYesterday format formatDistance formatDistanceStrict formatDistanceToNow formatDistanceToNowStrict formatDuration formatISO formatISO9075 formatISODuration formatRelative formatRFC3339 formatRFC7231 getDate getDay getDayOfYear getDaysInMonth getDaysInYear getDecade getHours getISODay getISOWeek getISOWeeksInYear getISOWeekYear getMilliseconds getMinutes getMonth getOverlappingDaysInIntervals getQuarter getSeconds getTime getUnixTime getWeek getWeekOfMonth getWeeksInMonth getWeekYear getYear hoursToMilliseconds hoursToMinutes hoursToSeconds intervalToDuration intlFormat intlFormatDistance isAfter isBefore isDate isEqual isExists isFirstDayOfMonth isFriday isFuture isLastDayOfMonth isLeapYear isMatch isMonday isPast isSameDay isSameHour isSameISOWeek isSameISOWeekYear isSameMinute isSameMonth isSameQuarter isSameSecond isSameWeek isSameYear isSaturday isSunday isThisHour isThisISOWeek isThisMinute isThisMonth isThisQuarter isThisSecond isThisWeek isThisYear isThursday isToday isTomorrow isTuesday isValid isWednesday isWeekend isWithinInterval isYesterday lastDayOfDecade lastDayOfISOWeek lastDayOfISOWeekYear lastDayOfMonth lastDayOfQuarter lastDayOfWeek lastDayOfYear lightFormat max milliseconds millisecondsToHours millisecondsToMinutes millisecondsToSeconds min minutesToHours minutesToMilliseconds minutesToSeconds monthsToQuarters monthsToYears nextDay nextFriday nextMonday nextSaturday nextSunday nextThursday nextTuesday nextWednesday parse parseISO parseJSON previousDay previousFriday previousMonday previousSaturday previousSunday previousThursday previousTuesday previousWednesday quartersToMonths quartersToYears roundToNearestMinutes secondsToHours secondsToMilliseconds secondsToMinutes set setDate setDay setDayOfYear setDefaultOptions setHours setISODay setISOWeek setISOWeekYear setMilliseconds setMinutes setMonth setQuarter setSeconds setWeek setWeekYear setYear startOfDay startOfDecade startOfHour startOfISOWeek startOfISOWeekYear startOfMinute startOfMonth startOfQuarter startOfSecond startOfToday startOfTomorrow startOfWeek startOfWeekYear startOfYear startOfYesterday sub subBusinessDays subDays subHours subISOWeekYears subMilliseconds subMinutes subMonths subQuarters subSeconds subWeeks subYears toDate weeksToDays yearsToMonths yearsToQuarters'''.split()
    locales = 'af ar ar-DZ ar-EG ar-MA ar-SA ar-TN az be be-tarask bg bn bs ca cs cy da de de-AT el en-AU en-CA en-GB en-IE en-IN en-NZ en-US en-ZA eo es et eu fa-IR fi fr fr-CA fr-CH fy gd gl gu he hi hr ht hu hy id is it it-CH ja ja-Hira ka kk km kn ko lb lt lv mk mn ms mt nb nl nl-BE nn oc pl pt pt-BR ro ru sk sl sq sr sr-Latn sv ta te th tr ug uk uz uz-Cyrl vi zh-CN zh-HK zh-TW'.split()
    files = [f'{prefix}{n}/{leaf}' for n in datefns for prefix in ('', 'esm/', 'fp/', 'esm/fp/')
             for leaf in (('index.js', 'index.d.ts') if not prefix.startswith('esm') else ('index.js',))]
    files += [f'{prefix}locale/{locale}/{leaf}' for locale in locales for prefix in ('', 'esm/')
              for leaf in ['index.js', 'index.d.ts', '_lib/formatDistance/index.js', '_lib/formatLong/index.js',
                           '_lib/formatRelative/index.js', '_lib/localize/index.js', '_lib/match/index.js']]
    store('date-fns', files)
    operators = '''audit auditTime buffer bufferCount bufferTime bufferToggle bufferWhen catchError combineAll combineLatest combineLatestAll combineLatestWith concat concatAll concatMap concatMapTo concatWith connect count debounce debounceTime defaultIfEmpty delay delayWhen dematerialize distinct distinctUntilChanged distinctUntilKeyChanged elementAt endWith every exhaust exhaustAll exhaustMap expand filter finalize find findIndex first groupBy ignoreElements isEmpty last map mapTo materialize max merge mergeAll mergeMap mergeMapTo mergeScan mergeWith min multicast observeOn onErrorResumeNext pairwise partition pluck publish publishBehavior publishLast publishReplay race raceWith reduce refCount repeat repeatWhen retry retryWhen sample sampleTime scan sequenceEqual share shareReplay single skip skipLast skipUntil skipWhile startWith subscribeOn switchAll switchMap switchMapTo switchScan take takeLast takeUntil takeWhile tap throttle throttleTime throwIfEmpty timeInterval timeout timeoutWith timestamp toArray window windowCount windowTime windowToggle windowWhen withLatestFrom zip zipAll zipWith'''.split()
    core = 'Observable Subject BehaviorSubject ReplaySubject AsyncSubject Subscriber Subscription Notification config scheduled/scheduled observable/bindCallback observable/bindNodeCallback observable/combineLatest observable/concat observable/connectable observable/defer observable/empty observable/forkJoin observable/from observable/fromEvent observable/fromEventPattern observable/generate observable/iif observable/interval observable/merge observable/never observable/of observable/onErrorResumeNext observable/pairs observable/partition observable/race observable/range observable/throwError observable/timer observable/using observable/zip scheduler/Action scheduler/AsyncAction scheduler/AsyncScheduler scheduler/AsapAction scheduler/AsapScheduler scheduler/AnimationFrameAction scheduler/AnimationFrameScheduler scheduler/QueueAction scheduler/QueueScheduler scheduler/VirtualTimeScheduler scheduler/animationFrame scheduler/asap scheduler/async scheduler/queue util/EmptyError util/NotFoundError util/ObjectUnsubscribedError util/SequenceError util/UnsubscriptionError util/args util/argsArgArrayOrObject util/argsOrArgArray util/arrRemove util/createErrorClass util/errorContext util/executeSchedule util/identity util/isArrayLike util/isDate util/isFunction util/isInteropObservable util/isObservable util/isPromise util/isScheduler util/lift util/mapOneOrManyArgs util/noop util/not util/pipe util/reportUnhandledError util/subscribeToArray util/throwUnobservableError'.split()
    rx = core + ['operators/' + n for n in operators]
    store('rxjs', ['src/internal/' + n + '.ts' for n in rx] +
          [f'dist/{build}/internal/{n}{ext}' for n in rx for build in ('cjs', 'esm', 'esm5', 'types')
           for ext in (('.d.ts', '.d.ts.map') if build == 'types' else ('.js', '.js.map'))])
    icons = '''Abc AccessAlarm AccessAlarms AccessTime Accessibility AccessibilityNew Accessible AccountBalance AccountBalanceWallet AccountBox AccountCircle Add AddAPhoto AddAlarm AddAlert AddBox AddBusiness AddCircle AddCircleOutline AddComment AddHome AddLocation AddPhotoAlternate AddRoad AddShoppingCart AddTask AddToDrive Adjust Air AirlineSeatFlat AirplanemodeActive Airplay AirportShuttle Alarm Album AllInbox AllInclusive AlternateEmail Analytics Anchor Android Announcement Apartment Api Apps Architecture Archive ArrowBack ArrowBackIos ArrowCircleDown ArrowCircleLeft ArrowCircleRight ArrowCircleUp ArrowDownward ArrowDropDown ArrowDropUp ArrowForward ArrowForwardIos ArrowLeft ArrowRight ArrowUpward Article AspectRatio Assessment Assignment Assistant AssistantPhoto AttachFile AttachMoney Attachment Attractions Audiotrack AutoAwesome AutoFixHigh Autorenew AvTimer BabyChangingStation BackHand Backup Badge BakeryDining Balance Balcony BarChart BatchPrediction Bathroom Bathtub BeachAccess Bed BedroomBaby BedroomChild BedroomParent Beenhere BikeScooter Biotech Blender Block Bluetooth BluetoothAudio BluetoothConnected Bolt Book Bookmark BookmarkAdd BookmarkBorder Bookmarks BorderAll BorderBottom BorderClear BorderColor BorderHorizontal BorderInner BorderLeft BorderOuter BorderRight BorderStyle BorderTop BorderVertical BrandingWatermark BreakfastDining Brightness1 Brightness2 Brightness3 Brightness4 Brightness5 Brightness6 Brightness7 BrokenImage BrowserUpdated BrunchDining Brush BubbleChart BugReport Build Business Cabin Cable Cached Cake CalendarMonth CalendarToday CalendarViewDay CalendarViewMonth CalendarViewWeek Call CallEnd CallMade CallMerge CallMissed CallReceived CallSplit Camera CameraAlt CameraEnhance CameraFront CameraRear CameraRoll Cameraswitch Campaign Cancel CarRental CarRepair CardGiftcard CardMembership CardTravel Carpenter Cases Casino Cast Castle Category Celebration CellTower Chair Chalet ChangeCircle ChangeHistory ChargingStation Chat ChatBubble ChatBubbleOutline Check CheckBox CheckBoxOutlineBlank CheckCircle CheckCircleOutline ChevronLeft ChevronRight ChildCare ChildFriendly Church Circle Class CleaningServices Clear Close ClosedCaption Cloud CloudCircle CloudDone CloudDownload CloudOff CloudQueue CloudUpload Code Coffee Collections ColorLens Colorize Comment Commute Compare Computer ConfirmationNumber Construction ContactMail ContactPage ContactPhone Contacts ContentCopy ContentCut ContentPaste ControlPoint Cookie Copyright Cottage Countertops Create CreditCard Crop CropFree CropSquare Dashboard DataArray DataObject Dataset DateRange Delete DeleteForever DeleteOutline DeliveryDining Description DesignServices DesktopMac DesktopWindows Details DeveloperBoard Devices Dialpad Diamond Dining DinnerDining Directions DirectionsBike DirectionsBoat DirectionsBus DirectionsCar DirectionsRailway DirectionsRun DirectionsSubway DirectionsTransit DirectionsWalk Discount Dns Dock DocumentScanner Domain Done DoneAll DoNotDisturb Download Drafts DragHandle Draw DriveEta DryCleaning Dvr East Eco Edit EditCalendar EditLocation Eject Elderly ElectricBike ElectricCar ElectricalServices Email EmojiEmotions EmojiEvents EmojiFlags EmojiFoodBeverage EmojiNature EmojiObjects EmojiPeople EmojiSymbols EmojiTransportation Engineering Equalizer Error ErrorOutline Euro Event EventAvailable EventBusy EventNote EventSeat ExitToApp Expand ExpandLess ExpandMore Explore Extension Face Facebook FactCheck FamilyRestroom FastForward FastRewind Favorite FavoriteBorder Fax Feedback Fence Festival FileCopy FileDownload FileOpen FileUpload Filter FilterAlt FilterList FilterNone Fingerprint FireExtinguisher Fireplace FirstPage FitnessCenter Flag Flaky Flare FlashOff FlashOn Flight FlightLand FlightTakeoff Flip Folder FolderCopy FolderOpen FolderShared FollowTheSigns FontDownload Forest FormatAlignCenter FormatAlignJustify FormatAlignLeft FormatAlignRight FormatBold FormatItalic FormatListBulleted FormatListNumbered FormatPaint FormatQuote FormatSize FormatUnderlined Forum Forward FreeBreakfast Fullscreen FullscreenExit Functions Gamepad Garage Gavel Gesture Gif Grade Gradient Grass GridOn Group Groups Hail Handyman Hardware Headphones Healing Hearing Help HelpOutline Hiking History Home Hotel HourglassBottom HourglassEmpty House Https Icecream Image Inbox Info Insights Inventory Key Keyboard Kitchen Label Landscape Language Laptop LastPage Launch Layers Leaderboard Lens LibraryBooks Light Lightbulb Link List LocalActivity LocalAirport LocalAtm LocalBar LocalCafe LocalDining LocalFlorist LocalGasStation LocalGroceryStore LocalHospital LocalHotel LocalLibrary LocalMall LocalMovies LocalOffer LocalParking LocalPharmacy LocalPhone LocalPizza LocalPolice LocalPostOffice LocalPrintshop LocalShipping LocalTaxi LocationCity LocationOff LocationOn Lock LockOpen Login Logout Looks LooksOne LooksTwo Loop Loyalty Luggage LunchDining Mail Map Markunread Menu MenuBook Mic MicOff MoreHoriz MoreVert Mouse Movie MusicNote MusicOff Nature Navigation NearMe Nightlight Notifications Numbers OndemandVideo Opacity OpenInBrowser OpenInFull OpenInNew OutdoorGrill Output Paid Palette PanTool Park Pause Payment People Person PersonAdd Pets Phone Photo PhotoAlbum PhotoCamera Piano Place PlayArrow Plumbing PlusOne Poll Pool Portrait Power Print Public PushPin Quiz Radio Receipt Recycling Refresh Remove Replay Report Restaurant Restore Rocket Room Route Router RssFeed Rule Save School Science Search Security Send Settings Share Shield ShoppingBag ShoppingBasket ShoppingCart Shower Shuffle Sick Signpost Skateboarding SkipNext SkipPrevious Slideshow Smartphone SmokeFree Sms Snooze Sort Spa SpaceBar Speaker Speed Spellcheck Sports Star StarBorder Stop Storage Store Straighten Style SubdirectoryArrowLeft SubdirectoryArrowRight Subscriptions Subway Summarize Sunny Support SwapHoriz Swipe Sync TableChart Tablet Tag TakeoutDining Task Terminal TextFields TheaterComedy Thermostat ThumbDown ThumbUp Timeline Timer Title Toc Today ToggleOff ToggleOn Toll Topic TouchApp Tour Toys Traffic Train Translate TrendingDown TrendingFlat TrendingUp Tune TurnedIn Tv Umbrella Undo UnfoldLess UnfoldMore Update Upload Usb Verified Videocam ViewAgenda ViewArray ViewCarousel ViewColumn ViewDay ViewList ViewModule ViewQuilt ViewStream Visibility VisibilityOff VoiceChat VolumeDown VolumeMute VolumeOff VolumeUp VpnKey Wallet Warning Watch Water WavingHand WbSunny Web Weekend Whatshot Widgets Wifi WineBar Work WorkspacePremium WrapText Yard ZoomIn ZoomOut'''.split()
    store('@mui/icons-material', [f'{prefix}{icon}{variant}{ext}' for icon in icons
          for variant in ('', 'Outlined', 'Rounded', 'Sharp', 'TwoTone')
          for prefix, ext in (('', '.js'), ('', '.d.ts'), ('esm/', '.js'))])
    store('react', ['index.js', 'jsx-runtime.js', 'jsx-dev-runtime.js', 'react.shared-subset.js'] +
          [f'cjs/{name}.{mode}.js' for name in ('react', 'react-jsx-runtime', 'react-jsx-dev-runtime')
           for mode in ('development', 'production.min', 'profiling.min')])
    store('react-dom', ['index.js', 'client.js', 'server.js', 'server.browser.js', 'server.node.js', 'test-utils.js'] +
          [f'cjs/{name}.{mode}.js' for name in ('react-dom', 'react-dom-server.browser', 'react-dom-server.node', 'react-dom-test-utils')
           for mode in ('development', 'production.min')])
    libs = ['es5', 'es6', 'dom', 'dom.iterable', 'webworker', 'webworker.importscripts', 'scripthost', 'decorators', 'decorators.legacy']
    libs += ['es2015'] + [f'es{year}{part}' for year in range(2016, 2024) for part in ('', '.full')]
    libs += ['es2015.' + n for n in ('core', 'collection', 'generator', 'iterable', 'promise', 'proxy', 'reflect', 'symbol', 'symbol.wellknown')]
    libs += ['es2020.' + n for n in ('bigint', 'date', 'number', 'promise', 'sharedmemory', 'string', 'symbol.wellknown', 'intl')]
    store('typescript', ['lib/lib.' + n + '.d.ts' for n in libs] + ['bin/tsc', 'bin/tsserver', 'lib/tsc.js', 'lib/typescript.js', 'lib/tsserver.js', 'lib/typescript.d.ts', 'lib/typingsInstaller.js', 'lib/tsserverlibrary.js'])
    store('esbuild', ['bin/esbuild', 'lib/main.js', 'lib/main.d.ts', 'install.js'])
    store('semver', ['index.js', 'bin/semver.js', 'range.bnf'] +
          ['classes/' + n + '.js' for n in ('semver', 'range', 'comparator')] +
          ['functions/' + n + '.js' for n in 'clean cmp coerce compare compare-build compare-loose diff eq gt gte inc lt lte major minor neq parse patch prerelease rcompare sort rsort satisfies valid'.split()] +
          ['ranges/' + n + '.js' for n in 'gtr intersects ltr max-satisfying min-satisfying min-version outside simplify subset to-comparators valid'.split()] +
          ['internal/' + n + '.js' for n in ('constants', 'debug', 'identifiers', 'parse-options', 're')])
    for name, files in {
        'vite': ['bin/vite.js', 'client.d.ts', 'dist/client/client.mjs', 'dist/client/env.mjs', 'dist/node/index.js', 'dist/node/index.d.ts', 'dist/node/cli.js'],
        'rollup': ['dist/rollup.js', 'dist/rollup.d.ts', 'dist/bin/rollup', 'dist/es/rollup.js', 'dist/shared/rollup.js', 'dist/shared/parseAst.js'],
        'debug': ['src/index.js', 'src/browser.js', 'src/node.js', 'src/common.js'],
        'ms': ['index.js'], 'picocolors': ['picocolors.js', 'picocolors.browser.js', 'picocolors.d.ts', 'types.d.ts'],
        'nanoid': ['index.js', 'index.browser.js', 'index.d.ts', 'non-secure/index.js', 'async/index.js', 'url-alphabet/index.js'],
        'scheduler': ['index.js', 'unstable_mock.js', 'cjs/scheduler.development.js', 'cjs/scheduler.production.min.js'],
        'postcss': ['lib/' + n + ext for n in 'at-rule comment container css-syntax-error declaration document fromJSON input lazy-result list map-generator node parse parser postcss previous-map result root rule stringifier stringify terminal-highlight tokenize warn-once warning'.split() for ext in ('.js', '.d.ts')],
        'source-map': ['source-map.js', 'source-map.d.ts'] + ['lib/' + n + '.js' for n in ('base64', 'base64-vlq', 'binary-search', 'mapping-list', 'source-map-consumer', 'source-map-generator', 'source-node', 'util')],
    }.items():
        store(name, files)
    return layouts


def plan(total=DEFAULT_BYTES):
    rng = random.Random(48210714)
    entries = []
    used_dates = set()

    def add(path, size, date, related=False):
        path = PurePosixPath(path)
        when = timestamp(date) if isinstance(date, str) else int(date)
        if 'node_modules' in path.parts and path.name != '.package-lock.json':
            when = NPM_MTIME
        else:
            # Second resolution survives exFAT; paired media may differ by seconds.
            while when in used_dates and not related:
                when += 1
            used_dates.add(when)
        assert when <= NOW
        text = text_for(path)
        size = max(int(size), len(text), 1)
        if path.suffix not in ('.dmg', '.iso'):
            while size % MIB == 0 or size & (size - 1) == 0:
                size += 1
        entries.append(Entry(path, size, when, text))
        return when

    def heavy(low, high):
        # Truncated lognormal with randomized tails, avoiding a pile at the bounds.
        value = rng.lognormvariate(0, .65) * low * 1.65
        while not low <= value <= high:
            value = rng.lognormvariate(0, .65) * low * 1.65
        return int(value * MIB)

    event_names = ['Cabin weekend', 'Spring garden', 'Coast road trip', 'Winter lights']
    counter = 4821
    for year in range(2018, 2026):
        for season, (month, title) in enumerate(zip((2, 4, 7, 11), event_names)):
            day = 5 + (year + season) % 19
            folder = f'Photos/{year}-{month:02d} {title}'
            shot = timestamp(f'{year}-{month:02d}-{day:02d}T08:12:17')
            for index in range(86):
                shot += rng.choice([2, 3, 7, 38, 93, 183, 481, 729])
                when = dt.datetime.fromtimestamp(shot, dt.timezone.utc)
                stem = f'IMG_{counter:04d}'
                if index % 29 == 0:
                    stem = f'DSC_{counter:04d}'
                    add(f'{folder}/{stem}.ARW', heavy(18, 38), shot)
                    add(f'{folder}/{stem}.xmp', rng.randrange(1801, 9721), shot + 1)
                elif index % 5 == 0:
                    stem = when.strftime('PXL_%Y%m%d_%H%M%S') + f'{rng.randrange(1000):03d}'
                    add(f'{folder}/{stem}.jpg', heavy(.7, 3.8), shot)
                else:
                    add(f'{folder}/{stem}.HEIC', heavy(.5, 2.8), shot)
                    if index % 23 == 0:
                        add(f'{folder}/{stem}.MOV', heavy(2, 7), shot + 1)
                counter += 1
    artists = ['The Lantern Hours', 'June Orchard', 'Paper Estuary', 'The Quiet Atlas', 'Moss Arcade', 'Wren Hollow',
               'Cedar House', 'Low Tide', 'Hannah Vale', 'River Glass', 'April Weather', 'Night Orchard',
               'Lena West', 'Sam Hollis', 'Red Kite', 'The Soft Hours', 'Ferry Lights', 'Blue Harbor',
               'Fern Choir', 'Map Room', 'Elena Moss', 'Fox Hollow', 'Small Islands', 'Pine Street',
               'The Slow Train', 'Ada Bell', 'East Window', 'Silver Lake', 'Owen Reed', 'Harbor Hymns']
    albums = ['Small Weather', 'Rooms Above the Water', 'Night Ferries', 'Western Windows', 'After the Rain',
              'Almost Home', 'Tidal Rooms', 'Cedar Lane', 'First Train', 'Open Window', 'Halfway to Morning',
              'Still Water', 'The Long Way Round', 'Apricot Sky', 'Last Ferry', 'Letters from the Coast',
              'Soft Landing', 'Porch Light', 'Days Away', 'Summer Maps', 'Paper Boats', 'Quiet Company',
              'Sunday Morning', 'All the Roads', 'Homeward', 'The Crossing', 'Green Rooms', 'In Passing', 'September', 'Field Notes']
    songs = ['Porch Light', 'Tidal Rooms', 'Cedar Lane', 'First Train', 'Open Window', 'Halfway to Morning',
             'Still Water', 'The Long Way Round', 'Apricot Sky', 'Last Ferry', 'Letters from the Coast', 'Soft Landing']
    for album in range(54):
        year = 1994 + album % 31
        date = timestamp(f'{year}-05-12T12:13:17') + rng.randrange(24000)
        folder = f'Music/{artists[album % 30]}/{albums[album % 30]} ({year})'
        for track, song in enumerate(rng.sample(songs, 10 + album % 3), 1):
            add(f'{folder}/{track:02d} {song}.m4a', heavy(2.4, 7.8), date + track * rng.randrange(12, 80))
        if album % 3 == 0:
            add(f'{folder}/cover.jpg', heavy(.04, .35), date + 1300)
    for year in range(2019, 2026):
        for name in ['Federal return', 'State return', 'W-2', '1099-INT', 'Donation summary', 'Property taxes', 'Filing confirmation']:
            add(f'Documents/Taxes/{year}/{name}.pdf', heavy(.04, .9), f'{year + 1}-03-19T17:21:13')
    groups = {
        'Work/Harbor survey': ['Meeting notes', 'Survey findings', 'Budget', 'Client letter', 'Site plan'],
        'Work/Workshop': ['Agenda', 'Registration', 'Expenses', 'Feedback', 'Handout'],
        'School/Geography': ['Reading notes', 'Coastal migration', 'Field observations', 'Bibliography', 'Landscape memory'],
        'School/Statistics': ['Problem set', 'Survey responses', 'Regression notes', 'Practice exam', 'Data summary'],
        'Recipes': ['Lemon and thyme chicken', 'Sunday focaccia', 'Summer tomato tart', 'Lentil soup', 'Apple cake'],
        'Letters/Scans': ['Insurance renewal', 'Library notice', 'Council letter', 'Lease signed', 'Dental estimate'],
        'Misc': ['Untitled', 'New document', 'Copy of notes', 'Moving checklist', 'old list'],
    }
    recipes = ['Lemon and thyme chicken', 'Sunday focaccia', 'Summer tomato tart', 'Lentil soup', 'Apple cake',
               'Mushroom risotto', 'Black bean chili', 'Banana bread', 'Roast carrots', 'Potato gratin',
               'Spinach pie', 'Coconut curry', 'Ginger cookies', 'Corn chowder', 'Peach crumble',
               'Roast cauliflower', 'Pesto pasta', 'Sourdough pancakes', 'Fish tacos', 'Vegetable stock',
               'Chickpea salad', 'Chocolate brownies', 'French onion soup', 'Ratatouille', 'Pear galette',
               'Sesame noodles', 'White bean stew', 'Pumpkin muffins', 'Rhubarb compote', 'Cinnamon rolls',
               'Falafel', 'Red pepper hummus', 'Oat biscuits', 'Wild rice salad', 'Broccoli quiche',
               'Chicken pot pie', 'Orange marmalade', 'Carrot cake', 'Tofu stir fry', 'Baked apples',
               'Eggplant parmesan', 'Greek salad', 'Lemon bars', 'Split pea soup', 'Cranberry sauce',
               'Salsa verde', 'Buttermilk scones', 'Apricot jam', 'Stuffed peppers', 'Garlic flatbread',
               'Zucchini fritters', 'Tomato soup', 'Granola', 'Pork dumplings', 'Maple squash',
               'Fried rice', 'Almond biscotti', 'Plum chutney', 'Polenta', 'Cucumber pickles']
    for folder, names in groups.items():
        for revision in range(12):
            for n, name in enumerate(names):
                ext = ('.pdf', '.docx', '.xlsx', '.md', '.csv')[n]
                if folder == 'Letters/Scans':
                    ext = '.pdf'
                if folder == 'Recipes':
                    label = recipes[revision * len(names) + n]
                elif folder.startswith('School/'):
                    label = f'2021 Spring/Week {revision + 1:02d}/{name}'
                elif folder.startswith('Work/'):
                    label = f'2024/{revision + 1:02d}/{name}'
                elif folder == 'Letters/Scans':
                    label = f'2023-{revision + 1:02d}-14 {name}'
                else:
                    label = name + ('' if revision == 0 else f' ({revision})')
                add(f'Documents/{folder}/{label}{ext}',
                    heavy(.002, .02) if ext in ('.md', '.csv') else heavy(.04, 2),
                    timestamp(f'{2021 if folder.startswith("School/") else 2024 if folder.startswith("Work/") else 2023 if folder == "Letters/Scans" else 2019 + revision % 7}-{revision + 1:02d}-14T09:42:17') + rng.randrange(20000))
    receipt_paths = set()
    for receipt in range(170):
        date = timestamp('2020-01-01T09:00:00') + rng.randrange(210000000)
        label = dt.datetime.fromtimestamp(date, dt.timezone.utc).strftime('%Y-%m-%d')
        merchant = rng.choice(['Hardware', 'Groceries', 'Bicycle shop', 'Bookstore', 'Train ticket'])
        stem = f'Documents/Receipts/{label[:4]}/{label} {merchant}'
        path = stem + '.pdf'
        duplicate = 1
        while path in receipt_paths:
            path = f'{stem} ({duplicate}).pdf'
            duplicate += 1
        receipt_paths.add(path)
        add(path, heavy(.015, .22), date)
    for index in range(24):
        date = timestamp('2026-09-12T08:00:00') + rng.randrange(35 * 86400)
        name = dt.datetime.fromtimestamp(date, dt.timezone.utc).strftime('Screenshot %Y-%m-%d at %H.%M.%S.png')
        add('Desktop/' + name, heavy(.15, 3), date)
    for name in ['Weekend errands.txt', 'Garden layout.pdf', 'Workshop slides.key', 'Receipt - bicycle repair.pdf', 'untitled.docx', 'Budget.xlsx']:
        add('Desktop/' + name, heavy(.02, 4), timestamp('2026-09-02T14:00:00') + rng.randrange(400000))
    downloads = ['SketchHarbor-2.8.1.dmg', 'SoundMeadow-4.2.pkg', 'TypeGarden-1.9.0.zip', 'AuroraLinux-22.04-desktop.iso']
    downloaded = set()
    for index in range(82):
        stem = rng.choice(['invoice', 'trail-map', 'booking', 'receipt', 'instructions', 'workshop-notes', 'wallpaper', 'photos-export'])
        ext = ['.pdf', '.zip', '.jpg', '.png'][index % 4]
        name = downloads[index] if index < 4 else stem + ext
        duplicate = 1
        while name in downloaded:
            name = f'{stem} ({duplicate}){ext}'
            duplicate += 1
        downloaded.add(name)
        add('Downloads/' + name, heavy(40, 180) if index < 4 else heavy(.04, 9),
            timestamp('2026-01-01T14:22:17') + rng.randrange(24000000))
    for name, size in [('Coast road trip.mov', 386), ('Birthday candles.mp4', 123), ('Lisbon tram ride.mov', 291), ('Lake house - rough cut.mov', 683)]:
        add('Movies/' + name, size * MIB + rng.randrange(981, 918217), timestamp('2024-08-03T15:00:00') + rng.randrange(1000000))
    projects = [('field-journal', '.ts', 'package.json'), ('trail-notes', '.rs', 'Cargo.toml'),
                ('pantry-planner', '.py', 'pyproject.toml'), ('WindowGarden', '.swift', 'WindowGarden.xcodeproj/project.pbxproj'),
                ('trail-map', '.ts', 'package.json'), ('recipe-browser', '.ts', 'package.json')]
    modules = ['catalog', 'search', 'storage', 'settings', 'timeline', 'format', 'import', 'export', 'preview', 'navigation', 'cache', 'workspace']
    for project, suffix, config in projects:
        base = f'Projects/{project}/'
        for name in ['README.md', config, '.git/HEAD', '.git/config', '.git/logs/HEAD', '.git/refs/heads/main']:
            add(base + name, rng.randrange(201, 4201), timestamp('2026-10-18T15:42:00') + rng.randrange(10000))
        for module in modules:
            for folder in ('src', 'tests'):
                add(base + folder + '/' + module + suffix, heavy(.001, .019), timestamp('2026-10-16T11:08:00') + rng.randrange(100000))
        # Loose commit/tree/blob objects from a few years of intermittent work.
        for commit in range(190):
            date = timestamp('2020-02-11T09:13:00') + commit * 1053001 + rng.randrange(90000)
            for _ in range(rng.randrange(3, 7)):
                digest = f'{rng.getrandbits(160):040x}'
                add(base + '.git/objects/' + digest[:2] + '/' + digest[2:], rng.randrange(151, 18971), date)
        digest = f'{rng.getrandbits(160):040x}'
        for ext in ('.pack', '.idx'):
            add(base + '.git/objects/pack/pack-' + digest + ext, heavy(.2, 8), '2026-09-23T18:42:17')
    layouts = package_layouts()
    for project in ('field-journal', 'trail-map', 'recipe-browser'):
        base = f'Projects/{project}/'
        install = timestamp('2026-09-24T12:10:00') + rng.randrange(1000000)
        install = add(base + 'package-lock.json', rng.randrange(170031, 420911), install)
        add(base + 'node_modules/.package-lock.json', rng.randrange(170031, 420911), install, related=True)
        for package, files in list(layouts.items()) + [(p, layouts[p.split('/')[-1]]) for p in ('debug/node_modules/ms', 'vite/node_modules/semver', 'rollup/node_modules/picocolors')]:
            for name in files:
                # Export stubs, declarations and bundled runtimes have very
                # different footprints even though all may end in .js or .ts.
                size = heavy(.00025, .009)
                if package == '@mui/icons-material':
                    size = rng.randrange(161, 351) if name.endswith('.d.ts') else rng.randrange(471, 1821)
                elif package == 'date-fns':
                    size = heavy(.0003, .004) if name.endswith('.d.ts') else heavy(.0005, .009)
                elif package == 'rxjs':
                    size = heavy(.0004, .014)
                elif package == 'lodash':
                    size = heavy(.0002, .004)
                    if name in ('lodash.js', 'lodash.min.js'):
                        size = 544127 if name == 'lodash.js' else 73041
                elif package in ('react', 'react-dom') and name.startswith('cjs/'):
                    size = heavy(.02, .18) if package == 'react' else heavy(.12, .72)
                elif package == 'typescript':
                    size = heavy(.002, .15)
                    if name in ('lib/typescript.js', 'lib/tsc.js'):
                        size = heavy(4, 9)
                elif package == 'esbuild' and name == 'bin/esbuild':
                    size = heavy(7, 11)
                elif package == 'rollup' and name == 'dist/shared/rollup.js':
                    size = heavy(.5, 1.1)
                if name in ('package.json', 'LICENSE', 'README.md'):
                    size = {'package.json': rng.randrange(701, 2901),
                            'LICENSE': rng.randrange(1041, 1571),
                            'README.md': rng.randrange(1801, 18711)}[name]
                add(base + 'node_modules/' + package + '/' + name, size, NPM_MTIME)
    for name, size in [('debug/deps/libtrail_notes-a9f6c2.rlib', 190), ('debug/incremental/trail-notes/session-cache.bin', 271), ('release/trail-notes', 22), ('debug/build/terrain-sys/out/libterrain.a', 183)]:
        add('Projects/trail-notes/target/' + name, size * MIB + rng.randrange(197, 98917), '2026-10-19T16:20:00')
    for name, size in [('Old MacBook/Documents/Collected essays.pdf', 18), ('Old MacBook/Pictures/Contact sheet.tiff', 41), ('field-journal-before-redesign.zip', 114), ('pantry-planner-summer.zip', 38)]:
        add('Archive/' + name, size * MIB + rng.randrange(171, 918271), '2020-03-14T09:40:00')
    for name, size in [('Manifest.db', 3), ('Info.json', .002), ('Camera Roll.zip', 190), ('Messages.db', 41), ('Voice Memos.m4a', 6), ('Application Data.tar', 310)]:
        add('Backups/Old phone - September 2021/' + name, size * MIB + rng.randrange(179, 91817), '2021-09-18T22:14:00')
    for name in ['Read me first.txt', 'Household inventory.csv', 'Places to visit.md']:
        add(name, rng.randrange(701, 3201), '2026-08-10T10:00:00')
    # Scale the varied distributions together, rather than hiding the difference
    # in a single giant cache. Tiny test volumes preserve text and file topology.
    floors = []
    for e in entries:
        floor = max(1, len(e.text))
        if e.path.suffix not in ('.dmg', '.iso'):
            while floor % MIB == 0 or floor & (floor - 1) == 0:
                floor += 1
        floors.append(floor)
    fixed = tesserae_entries()
    commit_date = max(e.mtime for e in fixed)
    git_files = {'.git/HEAD': b'ref: refs/heads/main\n',
                 '.git/config': b'[core]\n    repositoryformatversion = 0\n    bare = false\n',
                 '.git/refs/heads/main': b'7d0cf924923df4e8d1c9f36a6e982b62d5f4a371\n',
                 '.git/logs/HEAD': b'7d0cf924923df4e8d1c9f36a6e982b62d5f4a371 demo commit\n',
                 '.git/objects/pack/pack-7d0cf924923df4e8d1c9f36a6e982b62d5f4a371.pack': b'',
                 '.git/objects/pack/pack-7d0cf924923df4e8d1c9f36a6e982b62d5f4a371.idx': b''}
    for name, text in git_files.items():
        size = 3 * MIB + 719 if name.endswith('.pack') else 90131 if name.endswith('.idx') else len(text)
        fixed.append(Entry(PurePosixPath('Projects/tesserae') / name, size, commit_date, text))
    fixed_bytes = sum(e.size for e in fixed)
    minimum = sum(floors) + fixed_bytes
    if total < minimum:
        raise ValueError(f'--bytes must be at least {minimum} for the curated text')
    natural = sum(e.size for e in entries) + fixed_bytes
    scale = (total - minimum) / (natural - minimum)
    scaled = []
    for e, floor in zip(entries, floors):
        size = floor + int((e.size - floor) * scale)
        if e.path.suffix not in ('.dmg', '.iso'):
            while size % MIB == 0 or size & (size - 1) == 0:
                size += 1
        scaled.append(e._replace(size=size))
    # Rounding correction is distributed over large files; no size clamping spikes.
    deficit = total - fixed_bytes - sum(e.size for e in scaled)
    for index in sorted(range(len(scaled)), key=lambda i: scaled[i].size, reverse=True):
        if not deficit:
            break
        e = scaled[index]
        delta = max(-997, min(997, deficit))
        size = e.size + delta
        if size >= floors[index] and size % MIB and size & (size - 1):
            scaled[index] = e._replace(size=size)
            deficit -= delta
    assert deficit == 0
    return sorted(scaled + fixed, key=lambda e: str(e.path))


def root_subdir(value):
    if not value or value in ('.', '..') or '/' in value or '\\' in value or '\x00' in value:
        raise ValueError('--root-subdir must be a single folder name')
    return value


def validate_target(target, expected_uuid, required):
    resolved = target.resolve()
    home = Path.home().resolve()
    if resolved in (Path('/'), Path('/System/Volumes/Data')) or resolved == home or home in resolved.parents:
        raise ValueError('refusing system or home directory')
    if target.is_symlink() or not os.path.ismount(target):
        raise ValueError('target must be a mount point, not a symlink')
    info = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', str(target)]))
    if uuid.UUID(info.get('VolumeUUID', '')) != uuid.UUID(expected_uuid):
        raise ValueError('volume UUID does not match')
    roles = info.get('APFSVolumeRole', info.get('APFSVolumeRoles', []))
    if isinstance(roles, str):
        roles = [roles]
    if info.get('BootVolume') or {r.lower() for r in roles} & {'system', 'data', 'boot'}:
        raise ValueError('refusing APFS boot/Data volume')
    if Path(info.get('MountPoint', '')).resolve() != resolved:
        raise ValueError('diskutil mount point does not match')
    if shutil.disk_usage(target).free < required + 64 * MIB:
        raise ValueError('insufficient free space (including 64 MiB reserve)')


def pending_bytes(root, entries):
    """Preflight every destination without creating anything; charge only new files."""
    if not root.exists() and not root.is_symlink():
        return sum(e.size for e in entries)
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    pending = 0
    try:
        for e in entries:
            parent = os.dup(root_fd)
            try:
                missing = False
                for part in e.path.parts[:-1]:
                    try:
                        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    except FileNotFoundError:
                        missing = True
                        break
                    os.close(parent)
                    parent = child
                if missing:
                    pending += e.size
                    continue
                try:
                    existing = os.stat(e.path.name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    pending += e.size
                    continue
                if not (stat.S_ISREG(existing.st_mode) and existing.st_size == e.size
                        and existing.st_mtime_ns == e.mtime * 10**9):
                    raise ValueError(f'existing file conflicts: {e.path}')
            finally:
                os.close(parent)
    finally:
        os.close(root_fd)
    return pending


def remove_provenance(fd, parent, name):
    try:
        if hasattr(os, 'removexattr'):
            os.removexattr(fd, 'com.apple.provenance')
        else:
            # macOS Python omits os.removexattr. Use its descriptor-based
            # Darwin equivalent so cleanup cannot follow a replaced path.
            libc = ctypes.CDLL(None, use_errno=True)
            remove = libc.fremovexattr
            remove.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
            remove.restype = ctypes.c_int
            if remove(fd, b'com.apple.provenance', 0) != 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error))
    except OSError as error:
        if error.errno not in (errno.ENOATTR, errno.ENOTSUP):
            raise

    # Some macOS versions report successful removal while retaining protected
    # provenance. On exFAT it lives in AppleDouble: discard that sidecar only
    # when provenance is the sole attribute, preserving any other metadata.
    libc = ctypes.CDLL(None, use_errno=True)
    list_attributes = libc.flistxattr
    list_attributes.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    list_attributes.restype = ctypes.c_ssize_t
    size = list_attributes(fd, None, 0, 0)
    if size <= 0:
        return
    attributes = ctypes.create_string_buffer(size)
    count = list_attributes(fd, attributes, size, 0)
    if count != size or attributes.raw != b'com.apple.provenance\0':
        return
    sidecar = '._' + name
    try:
        side_fd = os.open(sidecar, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
    except FileNotFoundError:
        return
    try:
        before = os.fstat(side_fd)
        # Native AppleDouble magic and version, verified against an exFAT
        # sidecar. An unrelated user file named ._name must never be deleted.
        if not stat.S_ISREG(before.st_mode) or os.pread(side_fd, 8, 0) != bytes.fromhex('0005160700020000'):
            return
        current = os.stat(sidecar, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISREG(before.st_mode) and (before.st_dev, before.st_ino) == (current.st_dev, current.st_ino):
            os.unlink(sidecar, dir_fd=parent)
    finally:
        os.close(side_fd)


def write_tree(root, entries):
    # Directory descriptors plus O_NOFOLLOW keep pre-existing links and races
    # from redirecting writes outside the selected root. O_EXCL never replaces.
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    block = memoryview(bytes(4 * MIB))
    spaces = memoryview(b' ' * len(block))
    next_progress = 5
    created = set()
    folder_dates = {}
    for e in entries:
        for folder in e.path.parents:
            if str(folder) != ".":
                folder_dates[folder] = max(folder_dates.get(folder, 0), e.mtime)
    try:
        for completed, e in enumerate(entries, 1):
            parent = os.dup(root_fd)
            try:
                folder = PurePosixPath()
                for part in e.path.parts[:-1]:
                    folder = folder / part
                    try:
                        os.mkdir(part, dir_fd=parent)
                        created.add(folder)
                    except FileExistsError:
                        pass
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    os.close(parent)
                    parent = child
                name = e.path.name
                try:
                    existing = os.stat(name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    existing = None
                if existing is not None:
                    if stat.S_ISREG(existing.st_mode) and existing.st_size == e.size and existing.st_mtime_ns == e.mtime * 10**9:
                        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
                        try:
                            remove_provenance(fd, parent, name)
                        finally:
                            os.close(fd)
                        continue
                    raise ValueError(f'existing file conflicts: {e.path}')
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=parent)
                with os.fdopen(fd, 'wb', buffering=64 * 1024) as stream:
                    stream.write(e.text)
                    remaining = e.size - len(e.text)
                    # Text files use whitespace padding so they remain readable.
                    padding = spaces if e.text else block
                    while remaining:
                        chunk = padding[:min(remaining, len(padding))]
                        stream.write(chunk)
                        remaining -= len(chunk)
                    stream.flush()
                    os.utime(stream.fileno(), (e.mtime, e.mtime))
                    remove_provenance(stream.fileno(), parent, name)
            finally:
                os.close(parent)
                while next_progress <= 100 and completed * 100 >= next_progress * len(entries):
                    print(f'demo-volume: {next_progress}% ({completed}/{len(entries)} files)', file=sys.stderr)
                    next_progress += 5

        # Only folders created by this run receive deterministic dates. Existing
        # user folders keep their metadata; file writes never follow their links.
        for folder in sorted(created, key=lambda p: (-len(p.parts), str(p))):
            parent = os.dup(root_fd)
            try:
                for part in folder.parts:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    os.close(parent)
                    parent = child
                date = folder_dates[folder]
                os.utime(parent, (date, date))
            finally:
                os.close(parent)
    finally:
        os.close(root_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--target', required=True, type=Path)
    parser.add_argument('--volume-uuid', required=True, type=uuid.UUID)
    parser.add_argument('--bytes', type=int, default=DEFAULT_BYTES, help='total logical file bytes (default: 18 GiB)')
    parser.add_argument('--root-subdir', type=root_subdir)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--manifest', type=Path, help='required with --dry-run; parent must exist')
    args = parser.parse_args()
    try:
        entries = plan(args.bytes)
        if args.dry_run:
            if args.manifest is None:
                raise ValueError('--dry-run requires --manifest')
            # Exclusive creation prevents a manifest from overwriting user data.
            with args.manifest.open('x', newline='', encoding='utf-8') as stream:
                writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
                writer.writerow(['path', 'bytes', 'mtime'])
                for e in entries:
                    path = PurePosixPath(args.root_subdir) / e.path if args.root_subdir else e.path
                    writer.writerow([str(path), e.size, dt.datetime.fromtimestamp(e.mtime, dt.timezone.utc).isoformat()])
        else:
            validate_target(args.target, str(args.volume_uuid), 0)
            root = args.target / args.root_subdir if args.root_subdir else args.target
            required = pending_bytes(root, entries)
            validate_target(args.target, str(args.volume_uuid), required)
            root = args.target
            if args.root_subdir:
                root = root / args.root_subdir
                root.mkdir(exist_ok=True)
            write_tree(root, entries)
        print(f'{len(entries)} files, {sum(e.size for e in entries)} bytes')
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'demo-volume: {error}\n')


if __name__ == '__main__':
    main()
