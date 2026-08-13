import Foundation

/// Bundled emoji list (gemoji names/aliases). No Genmoji, no skin-tone variants.
enum EmojiCatalog {
    struct Item: Equatable {
        let glyph: String
        let name: String
        let keywords: String
        let category: Category
    }

    enum Category: Int, CaseIterable {
        case smileys
        case animals
        case food
        case activity
        case travel
        case objects
        case symbols
        case flags
    }

    /// Shown when the user has no recents yet (Apple-like frequently used).
    static let fallbackRecents: [String] = [
        "😂", "❤️", "😍", "😭", "😊", "🙏", "💕", "🥰", "👍", "😅",
        "😘", "💯", "😁", "🔥", "🥺", "🤔", "😉", "🤗", "😩", "👏",
        "✨", "😔", "💪", "🎉", "👀", "😏", "🙌", "😎", "💖", "😢",
        "🤣", "✅", "💀", "😡", "😴", "🫡",
    ]

    private static let packed = """
😀	grinning face	grinning face smile happy	0
😃	grinning face with big eyes	grinning face with big eyes smiley happy joy haha	0
😄	grinning face with smiling eyes	grinning face with smiling eyes smile happy joy laugh pleased	0
😁	beaming face with smiling eyes	beaming face with smiling eyes grin	0
😆	grinning squinting face	grinning squinting face laughing satisfied happy haha	0
😅	grinning face with sweat	grinning face with sweat smile hot	0
🤣	rolling on the floor laughing	rolling on the floor laughing rofl lol lmao	0
😂	face with tears of joy	face with tears of joy lol lmao	0
🙂	slightly smiling face	slightly smiling face	0
🙃	upside-down face	upside down face	0
🫠	melting face	melting face sarcasm dread	0
😉	winking face	winking face wink flirt	0
😊	smiling face with smiling eyes	smiling face with eyes blush proud smile	0
😇	smiling face with halo	smiling face with halo innocent angel	0
🥰	smiling face with hearts	smiling face with hearts three love	0
😍	smiling face with heart-eyes	smiling face with heart eyes love crush	0
🤩	star-struck	star struck eyes	0
😘	face blowing a kiss	face blowing a kiss kissing heart flirt	0
😗	kissing face	kissing face	0
☺️	smiling face	smiling face relaxed blush pleased	0
😚	kissing face with closed eyes	kissing face with closed eyes	0
😙	kissing face with smiling eyes	kissing face with smiling eyes	0
🥲	smiling face with tear	smiling face with tear	0
😋	face savoring food	face savoring food yum tongue lick	0
😛	face with tongue	face with tongue stuck out	0
😜	winking face with tongue	winking face with tongue stuck out eye prank silly	0
🤪	zany face	zany face goofy wacky	0
😝	squinting face with tongue	squinting face with tongue stuck out closed eyes prank	0
🤑	money-mouth face	money mouth face rich	0
🤗	smiling face with open hands	smiling face with open hands hugs	0
🤭	face with hand over mouth	face with hand over mouth quiet whoops	0
🫢	face with open eyes and hand over mouth	face with open eyes and hand over mouth gasp shock	0
🫣	face with peeking eye	face with peeking eye	0
🤫	shushing face	shushing face silence quiet	0
🤔	thinking face	thinking face	0
🫡	saluting face	saluting face respect	0
🤐	zipper-mouth face	zipper mouth face silence hush	0
🤨	face with raised eyebrow	face with raised eyebrow suspicious	0
😐	neutral face	neutral face meh	0
😑	expressionless face	expressionless face	0
😶	face without mouth	face without mouth no mute silence	0
🫥	dotted line face	dotted line face invisible	0
😶‍🌫️	face in clouds	face in clouds	0
😏	smirking face	smirking face smirk smug	0
😒	unamused face	unamused face meh	0
🙄	face with rolling eyes	face with rolling eyes roll	0
😬	grimacing face	grimacing face	0
😮‍💨	face exhaling	face exhaling	0
🤥	lying face	lying face liar	0
🫨	shaking face	shaking face shock	0
😌	relieved face	relieved face whew	0
😔	pensive face	pensive face	0
😪	sleepy face	sleepy face tired	0
🤤	drooling face	drooling face	0
😴	sleeping face	sleeping face zzz	0
😷	face with medical mask	face with medical mask sick ill	0
🤒	face with thermometer	face with thermometer sick	0
🤕	face with head-bandage	face with head bandage hurt	0
🤢	nauseated face	nauseated face sick barf disgusted	0
🤮	face vomiting	face vomiting barf sick	0
🤧	sneezing face	sneezing face achoo sick	0
🥵	hot face	hot face heat sweating	0
🥶	cold face	cold face freezing ice	0
🥴	woozy face	woozy face groggy	0
😵	face with crossed-out eyes	face with crossed out eyes dizzy	0
😵‍💫	face with spiral eyes	face with spiral eyes	0
🤯	exploding head	exploding head mind blown	0
🤠	cowboy hat face	cowboy hat face	0
🥳	partying face	partying face celebration birthday	0
🥸	disguised face	disguised face	0
😎	smiling face with sunglasses	smiling face with sunglasses cool	0
🤓	nerd face	nerd face geek glasses	0
🧐	face with monocle	face with monocle	0
😕	confused face	confused face	0
🫤	face with diagonal mouth	face with diagonal mouth confused	0
😟	worried face	worried face nervous	0
🙁	slightly frowning face	slightly frowning face	0
☹️	frowning face	frowning face	0
😮	face with open mouth	face with open mouth surprise impressed wow	0
😯	hushed face	hushed face silence speechless	0
😲	astonished face	astonished face amazed gasp	0
😳	flushed face	flushed face	0
🥺	pleading face	pleading face puppy eyes	0
🥹	face holding back tears	face holding back tears gratitude	0
😦	frowning face with open mouth	frowning face with open mouth	0
😧	anguished face	anguished face stunned	0
😨	fearful face	fearful face scared shocked oops	0
😰	anxious face with sweat	anxious face with sweat cold nervous	0
😥	sad but relieved face	sad but relieved face disappointed phew sweat nervous	0
😢	crying face	crying face cry sad tear	0
😭	loudly crying face	loudly crying face sob sad cry bawling	0
😱	face screaming in fear	face screaming in fear scream horror shocked	0
😖	confounded face	confounded face	0
😣	persevering face	persevering face persevere struggling	0
😞	disappointed face	disappointed face sad	0
😓	downcast face with sweat	downcast face with sweat	0
😩	weary face	weary face tired	0
😫	tired face	tired face upset whine	0
🥱	yawning face	yawning face	0
😤	face with steam from nose	face with steam from nose triumph smug	0
😡	enraged face	enraged face rage pout angry	0
😠	angry face	angry face mad annoyed	0
🤬	face with symbols on mouth	face with symbols on mouth cursing foul	0
😈	smiling face with horns	smiling face with horns imp devil evil	0
👿	angry face with horns	angry face with horns imp devil evil	0
💀	skull	skull dead danger poison	0
☠️	skull and crossbones	skull and crossbones danger pirate	0
💩	pile of poo	pile of poo hankey poop shit crap	0
🤡	clown face	clown face	0
👹	ogre	ogre japanese monster	0
👺	goblin	goblin japanese	0
👻	ghost	ghost halloween	0
👽	alien	alien ufo	0
👾	alien monster	alien monster space invader game retro	0
🤖	robot	robot	0
😺	grinning cat	grinning cat smiley	0
😸	grinning cat with smiling eyes	grinning cat with smiling eyes smile	0
😹	cat with tears of joy	cat with tears of joy	0
😻	smiling cat with heart-eyes	smiling cat with heart eyes	0
😼	cat with wry smile	cat with wry smile smirk	0
😽	kissing cat	kissing cat	0
🙀	weary cat	weary cat scream horror	0
😿	crying cat	crying cat face sad tear	0
😾	pouting cat	pouting cat	0
🙈	see-no-evil monkey	see no evil monkey blind ignore	0
🙉	hear-no-evil monkey	hear no evil monkey deaf	0
🙊	speak-no-evil monkey	speak no evil monkey mute hush	0
💌	love letter	love letter email envelope	0
💘	heart with arrow	heart with arrow cupid love	0
💝	heart with ribbon	heart with ribbon gift chocolates	0
💖	sparkling heart	sparkling heart	0
💗	growing heart	growing heart heartpulse	0
💓	beating heart	beating heart heartbeat	0
💞	revolving hearts	revolving hearts	0
💕	two hearts	two hearts	0
💟	heart decoration	heart decoration	0
❣️	heart exclamation	heart exclamation heavy	0
💔	broken heart	broken heart	0
❤️‍🔥	heart on fire	heart on fire	0
❤️‍🩹	mending heart	mending heart	0
❤️	red heart	red heart love	0
🩷	pink heart	pink heart	0
🧡	orange heart	orange heart	0
💛	yellow heart	yellow heart	0
💚	green heart	green heart	0
💙	blue heart	blue heart	0
🩵	light blue heart	light blue heart	0
💜	purple heart	purple heart	0
🤎	brown heart	brown heart	0
🖤	black heart	black heart	0
🩶	grey heart	grey heart	0
🤍	white heart	white heart	0
💋	kiss mark	kiss mark lipstick	0
💯	hundred points	hundred points 100 score perfect keep	0
💢	anger symbol	anger symbol angry	0
💥	collision	collision boom explode	0
💫	dizzy	dizzy star	0
💦	sweat droplets	sweat droplets drops water workout	0
💨	dashing away	dashing away dash wind blow fast	0
🕳️	hole	hole	0
💬	speech balloon	speech balloon comment	0
👁️‍🗨️	eye in speech bubble	eye in speech bubble	0
🗨️	left speech bubble	left speech bubble	0
🗯️	right anger bubble	right anger bubble	0
💭	thought balloon	thought balloon thinking	0
💤	ZZZ	zzz sleeping	0
👋	waving hand	waving hand wave goodbye	0
🤚	raised back of hand	raised back of hand	0
🖐️	hand with fingers splayed	hand with fingers splayed raised	0
✋	raised hand	raised hand highfive stop	0
🖖	vulcan salute	vulcan salute prosper spock	0
🫱	rightwards hand	rightwards hand	0
🫲	leftwards hand	leftwards hand	0
🫳	palm down hand	palm down hand	0
🫴	palm up hand	palm up hand	0
🫷	leftwards pushing hand	leftwards pushing hand	0
🫸	rightwards pushing hand	rightwards pushing hand	0
👌	OK hand	ok hand	0
🤌	pinched fingers	pinched fingers	0
🤏	pinching hand	pinching hand	0
✌️	victory hand	victory hand v peace	0
🤞	crossed fingers	crossed fingers luck hopeful	0
🫰	hand with index finger and thumb crossed	hand with index finger and thumb crossed	0
🤟	love-you gesture	love you gesture	0
🤘	sign of the horns	sign of the horns metal	0
🤙	call me hand	call me hand	0
👈	backhand index pointing left	backhand index pointing left point	0
👉	backhand index pointing right	backhand index pointing right point	0
👆	backhand index pointing up	backhand index pointing up point 2	0
🖕	middle finger	middle finger fu	0
👇	backhand index pointing down	backhand index pointing down point	0
☝️	index pointing up	index pointing up point	0
🫵	index pointing at the viewer	index pointing at the viewer	0
👍	thumbs up	thumbs up 1 thumbsup approve ok yes okay thumb	0
👎	thumbs down	thumbs down 1 thumbsdown disapprove bury no nope	0
✊	raised fist	raised fist power	0
👊	oncoming fist	oncoming fist facepunch punch attack	0
🤛	left-facing fist	left facing fist	0
🤜	right-facing fist	right facing fist	0
👏	clapping hands	clapping hands clap praise applause	0
🙌	raising hands	raising hands raised hooray	0
🫶	heart hands	heart hands love	0
👐	open hands	open hands	0
🤲	palms up together	palms up together	0
🤝	handshake	handshake deal	0
🙏	folded hands	folded hands pray please hope wish thanks thank	0
✍️	writing hand	writing hand	0
💅	nail polish	nail polish care beauty manicure	0
🤳	selfie	selfie	0
💪	flexed biceps	flexed biceps muscle flex bicep strong workout	0
🦾	mechanical arm	mechanical arm	0
🦿	mechanical leg	mechanical leg	0
🦵	leg	leg	0
🦶	foot	foot	0
👂	ear	ear hear sound listen	0
🦻	ear with hearing aid	ear with hearing aid	0
👃	nose	nose smell	0
🧠	brain	brain	0
🫀	anatomical heart	anatomical heart	0
🫁	lungs	lungs	0
🦷	tooth	tooth	0
🦴	bone	bone	0
👀	eyes	eyes look see watch	0
👁️	eye	eye	0
👅	tongue	tongue taste	0
👄	mouth	mouth lips kiss	0
🫦	biting lip	biting lip	0
👶	baby	baby child newborn	0
🧒	child	child	0
👦	boy	boy child	0
👧	girl	girl child	0
🧑	person	person adult	0
👱	person: blond hair	person blond hair haired	0
👨	man	man mustache father dad	0
🧔	person: beard	person beard bearded	0
🧔‍♂️	man: beard	man beard	0
🧔‍♀️	woman: beard	woman beard	0
👩	woman	woman girls	0
👱‍♀️	woman: blond hair	woman blond hair haired blonde	0
👱‍♂️	man: blond hair	man blond hair haired	0
🧓	older person	older person adult	0
👴	old man	old man older	0
👵	old woman	old woman older	0
🙍	person frowning	person frowning	0
🙍‍♂️	man frowning	man frowning	0
🙍‍♀️	woman frowning	woman frowning	0
🙎	person pouting	person pouting face	0
🙎‍♂️	man pouting	man pouting	0
🙎‍♀️	woman pouting	woman pouting	0
🙅	person gesturing NO	person gesturing no good stop halt denied	0
🙅‍♂️	man gesturing NO	man gesturing no good ng stop halt denied	0
🙅‍♀️	woman gesturing NO	woman gesturing no good ng stop halt denied	0
🙆	person gesturing OK	person gesturing ok	0
🙆‍♂️	man gesturing OK	man gesturing ok	0
🙆‍♀️	woman gesturing OK	woman gesturing ok	0
💁	person tipping hand	person tipping hand information desk	0
💁‍♂️	man tipping hand	man tipping hand sassy information	0
💁‍♀️	woman tipping hand	woman tipping hand sassy information	0
🙋	person raising hand	person raising hand	0
🙋‍♂️	man raising hand	man raising hand	0
🙋‍♀️	woman raising hand	woman raising hand	0
🧏	deaf person	deaf person	0
🧏‍♂️	deaf man	deaf man	0
🧏‍♀️	deaf woman	deaf woman	0
🙇	person bowing	person bowing bow respect thanks	0
🙇‍♂️	man bowing	man bowing respect thanks	0
🙇‍♀️	woman bowing	woman bowing respect thanks	0
🤦	person facepalming	person facepalming facepalm	0
🤦‍♂️	man facepalming	man facepalming	0
🤦‍♀️	woman facepalming	woman facepalming	0
🤷	person shrugging	person shrugging shrug	0
🤷‍♂️	man shrugging	man shrugging	0
🤷‍♀️	woman shrugging	woman shrugging	0
🧑‍⚕️	health worker	health worker	0
👨‍⚕️	man health worker	man health worker doctor nurse	0
👩‍⚕️	woman health worker	woman health worker doctor nurse	0
🧑‍🎓	student	student	0
👨‍🎓	man student	man student graduation	0
👩‍🎓	woman student	woman student graduation	0
🧑‍🏫	teacher	teacher	0
👨‍🏫	man teacher	man teacher school professor	0
👩‍🏫	woman teacher	woman teacher school professor	0
🧑‍⚖️	judge	judge	0
👨‍⚖️	man judge	man judge justice	0
👩‍⚖️	woman judge	woman judge justice	0
🧑‍🌾	farmer	farmer	0
👨‍🌾	man farmer	man farmer	0
👩‍🌾	woman farmer	woman farmer	0
🧑‍🍳	cook	cook	0
👨‍🍳	man cook	man cook chef	0
👩‍🍳	woman cook	woman cook chef	0
🧑‍🔧	mechanic	mechanic	0
👨‍🔧	man mechanic	man mechanic	0
👩‍🔧	woman mechanic	woman mechanic	0
🧑‍🏭	factory worker	factory worker	0
👨‍🏭	man factory worker	man factory worker	0
👩‍🏭	woman factory worker	woman factory worker	0
🧑‍💼	office worker	office worker	0
👨‍💼	man office worker	man office worker business	0
👩‍💼	woman office worker	woman office worker business	0
🧑‍🔬	scientist	scientist	0
👨‍🔬	man scientist	man scientist research	0
👩‍🔬	woman scientist	woman scientist research	0
🧑‍💻	technologist	technologist	0
👨‍💻	man technologist	man technologist coder	0
👩‍💻	woman technologist	woman technologist coder	0
🧑‍🎤	singer	singer	0
👨‍🎤	man singer	man singer rockstar	0
👩‍🎤	woman singer	woman singer rockstar	0
🧑‍🎨	artist	artist	0
👨‍🎨	man artist	man artist painter	0
👩‍🎨	woman artist	woman artist painter	0
🧑‍✈️	pilot	pilot	0
👨‍✈️	man pilot	man pilot	0
👩‍✈️	woman pilot	woman pilot	0
🧑‍🚀	astronaut	astronaut	0
👨‍🚀	man astronaut	man astronaut space	0
👩‍🚀	woman astronaut	woman astronaut space	0
🧑‍🚒	firefighter	firefighter	0
👨‍🚒	man firefighter	man firefighter	0
👩‍🚒	woman firefighter	woman firefighter	0
👮	police officer	police officer cop law	0
👮‍♂️	man police officer	man police officer policeman law cop	0
👮‍♀️	woman police officer	woman police officer policewoman law cop	0
🕵️	detective	detective sleuth	0
🕵️‍♂️	man detective	man detective male sleuth	0
🕵️‍♀️	woman detective	woman detective female sleuth	0
💂	guard	guard	0
💂‍♂️	man guard	man guard guardsman	0
💂‍♀️	woman guard	woman guard guardswoman	0
🥷	ninja	ninja	0
👷	construction worker	construction worker helmet	0
👷‍♂️	man construction worker	man construction worker helmet	0
👷‍♀️	woman construction worker	woman construction worker helmet	0
🫅	person with crown	person with crown	0
🤴	prince	prince crown royal	0
👸	princess	princess crown royal	0
👳	person wearing turban	person wearing turban with	0
👳‍♂️	man wearing turban	man wearing turban with	0
👳‍♀️	woman wearing turban	woman wearing turban with	0
👲	person with skullcap	person with skullcap man gua pi mao	0
🧕	woman with headscarf	woman with headscarf hijab	0
🤵	person in tuxedo	person in tuxedo groom marriage wedding	0
🤵‍♂️	man in tuxedo	man in tuxedo	0
🤵‍♀️	woman in tuxedo	woman in tuxedo	0
👰	person with veil	person with veil marriage wedding	0
👰‍♂️	man with veil	man with veil	0
👰‍♀️	woman with veil	woman with veil bride	0
🤰	pregnant woman	pregnant woman	0
🫃	pregnant man	pregnant man	0
🫄	pregnant person	pregnant person	0
🤱	breast-feeding	breast feeding nursing	0
👩‍🍼	woman feeding baby	woman feeding baby	0
👨‍🍼	man feeding baby	man feeding baby	0
🧑‍🍼	person feeding baby	person feeding baby	0
👼	baby angel	baby angel	0
🎅	Santa Claus	santa claus christmas	0
🤶	Mrs. Claus	mrs claus santa	0
🧑‍🎄	mx claus	mx claus	0
🦸	superhero	superhero	0
🦸‍♂️	man superhero	man superhero	0
🦸‍♀️	woman superhero	woman superhero	0
🦹	supervillain	supervillain	0
🦹‍♂️	man supervillain	man supervillain	0
🦹‍♀️	woman supervillain	woman supervillain	0
🧙	mage	mage wizard	0
🧙‍♂️	man mage	man mage wizard	0
🧙‍♀️	woman mage	woman mage wizard	0
🧚	fairy	fairy	0
🧚‍♂️	man fairy	man fairy	0
🧚‍♀️	woman fairy	woman fairy	0
🧛	vampire	vampire	0
🧛‍♂️	man vampire	man vampire	0
🧛‍♀️	woman vampire	woman vampire	0
🧜	merperson	merperson	0
🧜‍♂️	merman	merman	0
🧜‍♀️	mermaid	mermaid	0
🧝	elf	elf	0
🧝‍♂️	man elf	man elf	0
🧝‍♀️	woman elf	woman elf	0
🧞	genie	genie	0
🧞‍♂️	man genie	man genie	0
🧞‍♀️	woman genie	woman genie	0
🧟	zombie	zombie	0
🧟‍♂️	man zombie	man zombie	0
🧟‍♀️	woman zombie	woman zombie	0
🧌	troll	troll	0
💆	person getting massage	person getting massage spa	0
💆‍♂️	man getting massage	man getting massage spa	0
💆‍♀️	woman getting massage	woman getting massage spa	0
💇	person getting haircut	person getting haircut beauty	0
💇‍♂️	man getting haircut	man getting haircut	0
💇‍♀️	woman getting haircut	woman getting haircut	0
🚶	person walking	person walking	0
🚶‍♂️	man walking	man walking	0
🚶‍♀️	woman walking	woman walking	0
🧍	person standing	person standing	0
🧍‍♂️	man standing	man standing	0
🧍‍♀️	woman standing	woman standing	0
🧎	person kneeling	person kneeling	0
🧎‍♂️	man kneeling	man kneeling	0
🧎‍♀️	woman kneeling	woman kneeling	0
🧑‍🦯	person with white cane	person with white cane probing	0
👨‍🦯	man with white cane	man with white cane probing	0
👩‍🦯	woman with white cane	woman with white cane probing	0
🧑‍🦼	person in motorized wheelchair	person in motorized wheelchair	0
👨‍🦼	man in motorized wheelchair	man in motorized wheelchair	0
👩‍🦼	woman in motorized wheelchair	woman in motorized wheelchair	0
🧑‍🦽	person in manual wheelchair	person in manual wheelchair	0
👨‍🦽	man in manual wheelchair	man in manual wheelchair	0
👩‍🦽	woman in manual wheelchair	woman in manual wheelchair	0
🏃	person running	person running runner exercise workout marathon	0
🏃‍♂️	man running	man running exercise workout marathon	0
🏃‍♀️	woman running	woman running exercise workout marathon	0
💃	woman dancing	woman dancing dancer dress	0
🕺	man dancing	man dancing dancer	0
🕴️	person in suit levitating	person in suit levitating business	0
👯	people with bunny ears	people with bunny ears dancers	0
👯‍♂️	men with bunny ears	men with bunny ears dancing	0
👯‍♀️	women with bunny ears	women with bunny ears dancing	0
🧖	person in steamy room	person in steamy room sauna	0
🧖‍♂️	man in steamy room	man in steamy room sauna	0
🧖‍♀️	woman in steamy room	woman in steamy room sauna	0
🧗	person climbing	person climbing bouldering	0
🧗‍♂️	man climbing	man climbing bouldering	0
🧗‍♀️	woman climbing	woman climbing bouldering	0
🤺	person fencing	person fencing	0
🏇	horse racing	horse racing	0
⛷️	skier	skier	0
🏂	snowboarder	snowboarder	0
🏌️	person golfing	person golfing	0
🏌️‍♂️	man golfing	man golfing	0
🏌️‍♀️	woman golfing	woman golfing	0
🏄	person surfing	person surfing surfer	0
🏄‍♂️	man surfing	man surfing	0
🏄‍♀️	woman surfing	woman surfing	0
🚣	person rowing boat	person rowing boat rowboat	0
🚣‍♂️	man rowing boat	man rowing boat	0
🚣‍♀️	woman rowing boat	woman rowing boat	0
🏊	person swimming	person swimming swimmer	0
🏊‍♂️	man swimming	man swimming	0
🏊‍♀️	woman swimming	woman swimming	0
⛹️	person bouncing ball	person bouncing ball basketball	0
⛹️‍♂️	man bouncing ball	man bouncing ball basketball	0
⛹️‍♀️	woman bouncing ball	woman bouncing ball basketball	0
🏋️	person lifting weights	person lifting weights weight gym workout	0
🏋️‍♂️	man lifting weights	man lifting weights weight gym workout	0
🏋️‍♀️	woman lifting weights	woman lifting weights weight gym workout	0
🚴	person biking	person biking bicyclist	0
🚴‍♂️	man biking	man biking	0
🚴‍♀️	woman biking	woman biking	0
🚵	person mountain biking	person mountain biking bicyclist	0
🚵‍♂️	man mountain biking	man mountain biking	0
🚵‍♀️	woman mountain biking	woman mountain biking	0
🤸	person cartwheeling	person cartwheeling	0
🤸‍♂️	man cartwheeling	man cartwheeling	0
🤸‍♀️	woman cartwheeling	woman cartwheeling	0
🤼	people wrestling	people wrestling	0
🤼‍♂️	men wrestling	men wrestling	0
🤼‍♀️	women wrestling	women wrestling	0
🤽	person playing water polo	person playing water polo	0
🤽‍♂️	man playing water polo	man playing water polo	0
🤽‍♀️	woman playing water polo	woman playing water polo	0
🤾	person playing handball	person playing handball	0
🤾‍♂️	man playing handball	man playing handball	0
🤾‍♀️	woman playing handball	woman playing handball	0
🤹	person juggling	person juggling	0
🤹‍♂️	man juggling	man juggling	0
🤹‍♀️	woman juggling	woman juggling	0
🧘	person in lotus position	person in lotus position meditation	0
🧘‍♂️	man in lotus position	man in lotus position meditation	0
🧘‍♀️	woman in lotus position	woman in lotus position meditation	0
🛀	person taking bath	person taking bath shower	0
🛌	person in bed	person in bed sleeping	0
🧑‍🤝‍🧑	people holding hands	people holding hands couple date	0
👭	women holding hands	women holding hands two couple date	0
👫	woman and man holding hands	woman and man holding hands couple date	0
👬	men holding hands	men holding hands two couple date	0
💏	kiss	kiss couplekiss	0
👩‍❤️‍💋‍👨	kiss: woman, man	kiss woman man couplekiss	0
👨‍❤️‍💋‍👨	kiss: man, man	kiss man couplekiss	0
👩‍❤️‍💋‍👩	kiss: woman, woman	kiss woman couplekiss	0
💑	couple with heart	couple with heart	0
👩‍❤️‍👨	couple with heart: woman, man	couple with heart woman man	0
👨‍❤️‍👨	couple with heart: man, man	couple with heart man	0
👩‍❤️‍👩	couple with heart: woman, woman	couple with heart woman	0
👪	family	family home parents child	0
👨‍👩‍👦	family: man, woman, boy	family man woman boy	0
👨‍👩‍👧	family: man, woman, girl	family man woman girl	0
👨‍👩‍👧‍👦	family: man, woman, girl, boy	family man woman girl boy	0
👨‍👩‍👦‍👦	family: man, woman, boy, boy	family man woman boy	0
👨‍👩‍👧‍👧	family: man, woman, girl, girl	family man woman girl	0
👨‍👨‍👦	family: man, man, boy	family man boy	0
👨‍👨‍👧	family: man, man, girl	family man girl	0
👨‍👨‍👧‍👦	family: man, man, girl, boy	family man girl boy	0
👨‍👨‍👦‍👦	family: man, man, boy, boy	family man boy	0
👨‍👨‍👧‍👧	family: man, man, girl, girl	family man girl	0
👩‍👩‍👦	family: woman, woman, boy	family woman boy	0
👩‍👩‍👧	family: woman, woman, girl	family woman girl	0
👩‍👩‍👧‍👦	family: woman, woman, girl, boy	family woman girl boy	0
👩‍👩‍👦‍👦	family: woman, woman, boy, boy	family woman boy	0
👩‍👩‍👧‍👧	family: woman, woman, girl, girl	family woman girl	0
👨‍👦	family: man, boy	family man boy	0
👨‍👦‍👦	family: man, boy, boy	family man boy	0
👨‍👧	family: man, girl	family man girl	0
👨‍👧‍👦	family: man, girl, boy	family man girl boy	0
👨‍👧‍👧	family: man, girl, girl	family man girl	0
👩‍👦	family: woman, boy	family woman boy	0
👩‍👦‍👦	family: woman, boy, boy	family woman boy	0
👩‍👧	family: woman, girl	family woman girl	0
👩‍👧‍👦	family: woman, girl, boy	family woman girl boy	0
👩‍👧‍👧	family: woman, girl, girl	family woman girl	0
🗣️	speaking head	speaking head	0
👤	bust in silhouette	bust in silhouette user	0
👥	busts in silhouette	busts in silhouette users group team	0
🫂	people hugging	people hugging	0
👣	footprints	footprints feet tracks	0
🐵	monkey face	monkey face	1
🐒	monkey	monkey	1
🦍	gorilla	gorilla	1
🦧	orangutan	orangutan	1
🐶	dog face	dog face pet	1
🐕	dog	dog dog2	1
🦮	guide dog	guide dog	1
🐕‍🦺	service dog	service dog	1
🐩	poodle	poodle dog	1
🐺	wolf	wolf	1
🦊	fox	fox face	1
🦝	raccoon	raccoon	1
🐱	cat face	cat face pet	1
🐈	cat	cat cat2	1
🐈‍⬛	black cat	black cat	1
🦁	lion	lion	1
🐯	tiger face	tiger face	1
🐅	tiger	tiger tiger2	1
🐆	leopard	leopard	1
🐴	horse face	horse face	1
🫎	moose	moose canada	1
🫏	donkey	donkey mule	1
🐎	horse	horse racehorse speed	1
🦄	unicorn	unicorn	1
🦓	zebra	zebra	1
🦌	deer	deer	1
🦬	bison	bison	1
🐮	cow face	cow face	1
🐂	ox	ox	1
🐃	water buffalo	water buffalo	1
🐄	cow	cow cow2	1
🐷	pig face	pig face	1
🐖	pig	pig pig2	1
🐗	boar	boar	1
🐽	pig nose	pig nose	1
🐏	ram	ram	1
🐑	ewe	ewe sheep	1
🐐	goat	goat	1
🐪	camel	camel dromedary desert	1
🐫	two-hump camel	two hump camel	1
🦙	llama	llama	1
🦒	giraffe	giraffe	1
🐘	elephant	elephant	1
🦣	mammoth	mammoth	1
🦏	rhinoceros	rhinoceros	1
🦛	hippopotamus	hippopotamus	1
🐭	mouse face	mouse face	1
🐁	mouse	mouse mouse2	1
🐀	rat	rat	1
🐹	hamster	hamster pet	1
🐰	rabbit face	rabbit face bunny	1
🐇	rabbit	rabbit rabbit2	1
🐿️	chipmunk	chipmunk	1
🦫	beaver	beaver	1
🦔	hedgehog	hedgehog	1
🦇	bat	bat	1
🐻	bear	bear	1
🐻‍❄️	polar bear	polar bear	1
🐨	koala	koala	1
🐼	panda	panda face	1
🦥	sloth	sloth	1
🦦	otter	otter	1
🦨	skunk	skunk	1
🦘	kangaroo	kangaroo	1
🦡	badger	badger	1
🐾	paw prints	paw prints feet	1
🦃	turkey	turkey thanksgiving	1
🐔	chicken	chicken	1
🐓	rooster	rooster	1
🐣	hatching chick	hatching chick	1
🐤	baby chick	baby chick	1
🐥	front-facing baby chick	front facing baby chick hatched	1
🐦	bird	bird	1
🐧	penguin	penguin	1
🕊️	dove	dove peace	1
🦅	eagle	eagle	1
🦆	duck	duck	1
🦢	swan	swan	1
🦉	owl	owl	1
🦤	dodo	dodo	1
🪶	feather	feather	1
🦩	flamingo	flamingo	1
🦚	peacock	peacock	1
🦜	parrot	parrot	1
🪽	wing	wing fly	1
🐦‍⬛	black bird	black bird	1
🪿	goose	goose honk	1
🐸	frog	frog	1
🐊	crocodile	crocodile	1
🐢	turtle	turtle slow	1
🦎	lizard	lizard	1
🐍	snake	snake	1
🐲	dragon face	dragon face	1
🐉	dragon	dragon	1
🦕	sauropod	sauropod dinosaur	1
🦖	T-Rex	t rex dinosaur	1
🐳	spouting whale	spouting whale sea	1
🐋	whale	whale whale2	1
🐬	dolphin	dolphin flipper	1
🦭	seal	seal	1
🐟	fish	fish	1
🐠	tropical fish	tropical fish	1
🐡	blowfish	blowfish	1
🦈	shark	shark	1
🐙	octopus	octopus	1
🐚	spiral shell	spiral shell sea beach	1
🪸	coral	coral	1
🪼	jellyfish	jellyfish	1
🐌	snail	snail slow	1
🦋	butterfly	butterfly	1
🐛	bug	bug	1
🐜	ant	ant	1
🐝	honeybee	honeybee bee	1
🪲	beetle	beetle	1
🐞	lady beetle	lady beetle bug	1
🦗	cricket	cricket	1
🪳	cockroach	cockroach	1
🕷️	spider	spider	1
🕸️	spider web	spider web	1
🦂	scorpion	scorpion	1
🦟	mosquito	mosquito	1
🪰	fly	fly	1
🪱	worm	worm	1
🦠	microbe	microbe germ	1
💐	bouquet	bouquet flowers	1
🌸	cherry blossom	cherry blossom flower spring	1
💮	white flower	white flower	1
🪷	lotus	lotus	1
🏵️	rosette	rosette	1
🌹	rose	rose flower	1
🥀	wilted flower	wilted flower	1
🌺	hibiscus	hibiscus	1
🌻	sunflower	sunflower	1
🌼	blossom	blossom	1
🌷	tulip	tulip flower	1
🪻	hyacinth	hyacinth	1
🌱	seedling	seedling plant	1
🪴	potted plant	potted plant	1
🌲	evergreen tree	evergreen tree wood	1
🌳	deciduous tree	deciduous tree wood	1
🌴	palm tree	palm tree	1
🌵	cactus	cactus	1
🌾	sheaf of rice	sheaf of rice ear	1
🌿	herb	herb	1
☘️	shamrock	shamrock	1
🍀	four leaf clover	four leaf clover luck	1
🍁	maple leaf	maple leaf canada	1
🍂	fallen leaf	fallen leaf autumn	1
🍃	leaf fluttering in wind	leaf fluttering in wind leaves	1
🪹	empty nest	empty nest	1
🪺	nest with eggs	nest with eggs	1
🍄	mushroom	mushroom fungus	1
🍇	grapes	grapes	2
🍈	melon	melon	2
🍉	watermelon	watermelon	2
🍊	tangerine	tangerine orange mandarin	2
🍋	lemon	lemon	2
🍌	banana	banana fruit	2
🍍	pineapple	pineapple	2
🥭	mango	mango	2
🍎	red apple	red apple	2
🍏	green apple	green apple fruit	2
🍐	pear	pear	2
🍑	peach	peach	2
🍒	cherries	cherries fruit	2
🍓	strawberry	strawberry fruit	2
🫐	blueberries	blueberries	2
🥝	kiwi fruit	kiwi fruit	2
🍅	tomato	tomato	2
🫒	olive	olive	2
🥥	coconut	coconut	2
🥑	avocado	avocado	2
🍆	eggplant	eggplant aubergine	2
🥔	potato	potato	2
🥕	carrot	carrot	2
🌽	ear of corn	ear of corn	2
🌶️	hot pepper	hot pepper spicy	2
🫑	bell pepper	bell pepper	2
🥒	cucumber	cucumber	2
🥬	leafy green	leafy green	2
🥦	broccoli	broccoli	2
🧄	garlic	garlic	2
🧅	onion	onion	2
🥜	peanuts	peanuts	2
🫘	beans	beans	2
🌰	chestnut	chestnut	2
🫚	ginger root	ginger root	2
🫛	pea pod	pea pod	2
🍞	bread	bread toast	2
🥐	croissant	croissant	2
🥖	baguette bread	baguette bread	2
🫓	flatbread	flatbread	2
🥨	pretzel	pretzel	2
🥯	bagel	bagel	2
🥞	pancakes	pancakes	2
🧇	waffle	waffle	2
🧀	cheese wedge	cheese wedge	2
🍖	meat on bone	meat on bone	2
🍗	poultry leg	poultry leg meat chicken	2
🥩	cut of meat	cut of meat	2
🥓	bacon	bacon	2
🍔	hamburger	hamburger burger	2
🍟	french fries	french fries	2
🍕	pizza	pizza	2
🌭	hot dog	hot dog hotdog	2
🥪	sandwich	sandwich	2
🌮	taco	taco	2
🌯	burrito	burrito	2
🫔	tamale	tamale	2
🥙	stuffed flatbread	stuffed flatbread	2
🧆	falafel	falafel	2
🥚	egg	egg	2
🍳	cooking	cooking fried egg breakfast	2
🥘	shallow pan of food	shallow pan of food paella curry	2
🍲	pot of food	pot of food stew	2
🫕	fondue	fondue	2
🥣	bowl with spoon	bowl with spoon	2
🥗	green salad	green salad	2
🍿	popcorn	popcorn	2
🧈	butter	butter	2
🧂	salt	salt	2
🥫	canned food	canned food	2
🍱	bento box	bento box	2
🍘	rice cracker	rice cracker	2
🍙	rice ball	rice ball	2
🍚	cooked rice	cooked rice	2
🍛	curry rice	curry rice	2
🍜	steaming bowl	steaming bowl ramen noodle	2
🍝	spaghetti	spaghetti pasta	2
🍠	roasted sweet potato	roasted sweet potato	2
🍢	oden	oden	2
🍣	sushi	sushi	2
🍤	fried shrimp	fried shrimp tempura	2
🍥	fish cake with swirl	fish cake with swirl	2
🥮	moon cake	moon cake	2
🍡	dango	dango	2
🥟	dumpling	dumpling	2
🥠	fortune cookie	fortune cookie	2
🥡	takeout box	takeout box	2
🦀	crab	crab	2
🦞	lobster	lobster	2
🦐	shrimp	shrimp	2
🦑	squid	squid	2
🦪	oyster	oyster	2
🍦	soft ice cream	soft ice cream icecream	2
🍧	shaved ice	shaved ice	2
🍨	ice cream	ice cream	2
🍩	doughnut	doughnut	2
🍪	cookie	cookie	2
🎂	birthday cake	birthday cake party	2
🍰	shortcake	shortcake cake dessert	2
🧁	cupcake	cupcake	2
🥧	pie	pie	2
🍫	chocolate bar	chocolate bar	2
🍬	candy	candy sweet	2
🍭	lollipop	lollipop	2
🍮	custard	custard	2
🍯	honey pot	honey pot	2
🍼	baby bottle	baby bottle milk	2
🥛	glass of milk	glass of milk	2
☕	hot beverage	hot beverage coffee cafe espresso	2
🫖	teapot	teapot	2
🍵	teacup without handle	teacup without handle tea green breakfast	2
🍶	sake	sake	2
🍾	bottle with popping cork	bottle with popping cork champagne bubbly celebration	2
🍷	wine glass	wine glass	2
🍸	cocktail glass	cocktail glass drink	2
🍹	tropical drink	tropical drink summer vacation	2
🍺	beer mug	beer mug drink	2
🍻	clinking beer mugs	clinking beer mugs beers drinks	2
🥂	clinking glasses	clinking glasses cheers toast	2
🥃	tumbler glass	tumbler glass whisky	2
🫗	pouring liquid	pouring liquid	2
🥤	cup with straw	cup with straw	2
🧋	bubble tea	bubble tea	2
🧃	beverage box	beverage box	2
🧉	mate	mate	2
🧊	ice	ice cube	2
🥢	chopsticks	chopsticks	2
🍽️	fork and knife with plate	fork and knife with plate cutlery dining dinner	2
🍴	fork and knife	fork and knife cutlery	2
🥄	spoon	spoon	2
🔪	kitchen knife	kitchen knife hocho cut chop	2
🫙	jar	jar	2
🏺	amphora	amphora	2
🌍	globe showing Europe-Africa	globe showing europe africa earth world international	4
🌎	globe showing Americas	globe showing americas earth world international	4
🌏	globe showing Asia-Australia	globe showing asia australia earth world international	4
🌐	globe with meridians	globe with meridians world global international	4
🗺️	world map	world map travel	4
🗾	map of Japan	map of japan	4
🧭	compass	compass	4
🏔️	snow-capped mountain	snow capped mountain	4
⛰️	mountain	mountain	4
🌋	volcano	volcano	4
🗻	mount fuji	mount fuji	4
🏕️	camping	camping	4
🏖️	beach with umbrella	beach with umbrella	4
🏜️	desert	desert	4
🏝️	desert island	desert island	4
🏞️	national park	national park	4
🏟️	stadium	stadium	4
🏛️	classical building	classical building	4
🏗️	building construction	building construction	4
🧱	brick	brick bricks	4
🪨	rock	rock	4
🪵	wood	wood	4
🛖	hut	hut	4
🏘️	houses	houses	4
🏚️	derelict house	derelict house	4
🏠	house	house	4
🏡	house with garden	house with garden	4
🏢	office building	office building	4
🏣	Japanese post office	japanese post office	4
🏤	post office	post office european	4
🏥	hospital	hospital	4
🏦	bank	bank	4
🏨	hotel	hotel	4
🏩	love hotel	love hotel	4
🏪	convenience store	convenience store	4
🏫	school	school	4
🏬	department store	department store	4
🏭	factory	factory	4
🏯	Japanese castle	japanese castle	4
🏰	castle	castle european	4
💒	wedding	wedding marriage	4
🗼	Tokyo tower	tokyo tower	4
🗽	Statue of Liberty	statue of liberty	4
⛪	church	church	4
🕌	mosque	mosque	4
🛕	hindu temple	hindu temple	4
🕍	synagogue	synagogue	4
⛩️	shinto shrine	shinto shrine	4
🕋	kaaba	kaaba	4
⛲	fountain	fountain	4
⛺	tent	tent camping	4
🌁	foggy	foggy karl	4
🌃	night with stars	night with stars	4
🏙️	cityscape	cityscape skyline	4
🌄	sunrise over mountains	sunrise over mountains	4
🌅	sunrise	sunrise	4
🌆	cityscape at dusk	cityscape at dusk city sunset	4
🌇	sunset	sunset city sunrise	4
🌉	bridge at night	bridge at night	4
♨️	hot springs	hot springs hotsprings	4
🎠	carousel horse	carousel horse	4
🛝	playground slide	playground slide	4
🎡	ferris wheel	ferris wheel	4
🎢	roller coaster	roller coaster	4
💈	barber pole	barber pole	4
🎪	circus tent	circus tent	4
🚂	locomotive	locomotive steam train	4
🚃	railway car	railway car	4
🚄	high-speed train	high speed train bullettrain side	4
🚅	bullet train	bullet train bullettrain front	4
🚆	train	train train2	4
🚇	metro	metro	4
🚈	light rail	light rail	4
🚉	station	station	4
🚊	tram	tram	4
🚝	monorail	monorail	4
🚞	mountain railway	mountain railway	4
🚋	tram car	tram car train	4
🚌	bus	bus	4
🚍	oncoming bus	oncoming bus	4
🚎	trolleybus	trolleybus	4
🚐	minibus	minibus	4
🚑	ambulance	ambulance	4
🚒	fire engine	fire engine	4
🚓	police car	police car	4
🚔	oncoming police car	oncoming police car	4
🚕	taxi	taxi	4
🚖	oncoming taxi	oncoming taxi	4
🚗	automobile	automobile car red	4
🚘	oncoming automobile	oncoming automobile	4
🚙	sport utility vehicle	sport utility vehicle blue car	4
🛻	pickup truck	pickup truck	4
🚚	delivery truck	delivery truck	4
🚛	articulated lorry	articulated lorry	4
🚜	tractor	tractor	4
🏎️	racing car	racing car	4
🏍️	motorcycle	motorcycle	4
🛵	motor scooter	motor scooter	4
🦽	manual wheelchair	manual wheelchair	4
🦼	motorized wheelchair	motorized wheelchair	4
🛺	auto rickshaw	auto rickshaw	4
🚲	bicycle	bicycle bike	4
🛴	kick scooter	kick scooter	4
🛹	skateboard	skateboard	4
🛼	roller skate	roller skate	4
🚏	bus stop	bus stop busstop	4
🛣️	motorway	motorway	4
🛤️	railway track	railway track	4
🛢️	oil drum	oil drum	4
⛽	fuel pump	fuel pump fuelpump	4
🛞	wheel	wheel	4
🚨	police car light	police car light rotating 911 emergency	4
🚥	horizontal traffic light	horizontal traffic light	4
🚦	vertical traffic light	vertical traffic light semaphore	4
🛑	stop sign	stop sign	4
🚧	construction	construction wip	4
⚓	anchor	anchor ship	4
🛟	ring buoy	ring buoy life preserver	4
⛵	sailboat	sailboat boat	4
🛶	canoe	canoe	4
🚤	speedboat	speedboat ship	4
🛳️	passenger ship	passenger ship cruise	4
⛴️	ferry	ferry	4
🛥️	motor boat	motor boat	4
🚢	ship	ship	4
✈️	airplane	airplane flight	4
🛩️	small airplane	small airplane flight	4
🛫	airplane departure	airplane departure flight	4
🛬	airplane arrival	airplane arrival flight	4
🪂	parachute	parachute	4
💺	seat	seat	4
🚁	helicopter	helicopter	4
🚟	suspension railway	suspension railway	4
🚠	mountain cableway	mountain cableway	4
🚡	aerial tramway	aerial tramway	4
🛰️	satellite	satellite artificial orbit space	4
🚀	rocket	rocket ship launch	4
🛸	flying saucer	flying saucer ufo	4
🛎️	bellhop bell	bellhop bell	4
🧳	luggage	luggage	4
⌛	hourglass done	hourglass done time	4
⏳	hourglass not done	hourglass not done flowing sand time	4
⌚	watch	watch time	4
⏰	alarm clock	alarm clock morning	4
⏱️	stopwatch	stopwatch	4
⏲️	timer clock	timer clock	4
🕰️	mantelpiece clock	mantelpiece clock	4
🕛	twelve o’clock	twelve o clock clock12	4
🕧	twelve-thirty	twelve thirty clock1230	4
🕐	one o’clock	one o clock clock1	4
🕜	one-thirty	one thirty clock130	4
🕑	two o’clock	two o clock clock2	4
🕝	two-thirty	two thirty clock230	4
🕒	three o’clock	three o clock clock3	4
🕞	three-thirty	three thirty clock330	4
🕓	four o’clock	four o clock clock4	4
🕟	four-thirty	four thirty clock430	4
🕔	five o’clock	five o clock clock5	4
🕠	five-thirty	five thirty clock530	4
🕕	six o’clock	six o clock clock6	4
🕡	six-thirty	six thirty clock630	4
🕖	seven o’clock	seven o clock clock7	4
🕢	seven-thirty	seven thirty clock730	4
🕗	eight o’clock	eight o clock clock8	4
🕣	eight-thirty	eight thirty clock830	4
🕘	nine o’clock	nine o clock clock9	4
🕤	nine-thirty	nine thirty clock930	4
🕙	ten o’clock	ten o clock clock10	4
🕥	ten-thirty	ten thirty clock1030	4
🕚	eleven o’clock	eleven o clock clock11	4
🕦	eleven-thirty	eleven thirty clock1130	4
🌑	new moon	new moon	4
🌒	waxing crescent moon	waxing crescent moon	4
🌓	first quarter moon	first quarter moon	4
🌔	waxing gibbous moon	waxing gibbous moon	4
🌕	full moon	full moon	4
🌖	waning gibbous moon	waning gibbous moon	4
🌗	last quarter moon	last quarter moon	4
🌘	waning crescent moon	waning crescent moon	4
🌙	crescent moon	crescent moon night	4
🌚	new moon face	new moon face with	4
🌛	first quarter moon face	first quarter moon face with	4
🌜	last quarter moon face	last quarter moon face with	4
🌡️	thermometer	thermometer	4
☀️	sun	sun sunny weather	4
🌝	full moon face	full moon face with	4
🌞	sun with face	sun with face summer	4
🪐	ringed planet	ringed planet	4
⭐	star	star	4
🌟	glowing star	glowing star star2	4
🌠	shooting star	shooting star stars	4
🌌	milky way	milky way	4
☁️	cloud	cloud	4
⛅	sun behind cloud	sun behind cloud partly sunny weather	4
⛈️	cloud with lightning and rain	cloud with lightning and rain	4
🌤️	sun behind small cloud	sun behind small cloud	4
🌥️	sun behind large cloud	sun behind large cloud	4
🌦️	sun behind rain cloud	sun behind rain cloud	4
🌧️	cloud with rain	cloud with rain	4
🌨️	cloud with snow	cloud with snow	4
🌩️	cloud with lightning	cloud with lightning	4
🌪️	tornado	tornado	4
🌫️	fog	fog	4
🌬️	wind face	wind face	4
🌀	cyclone	cyclone swirl	4
🌈	rainbow	rainbow	4
🌂	closed umbrella	closed umbrella weather rain	4
☂️	umbrella	umbrella open	4
☔	umbrella with rain drops	umbrella with rain drops weather	4
⛱️	umbrella on ground	umbrella on ground parasol beach	4
⚡	high voltage	high voltage zap lightning thunder	4
❄️	snowflake	snowflake winter cold weather	4
☃️	snowman	snowman with snow winter christmas	4
⛄	snowman without snow	snowman without snow winter	4
☄️	comet	comet	4
🔥	fire	fire burn lit hot	4
💧	droplet	droplet water	4
🌊	water wave	water wave ocean sea	4
🎃	jack-o-lantern	jack o lantern halloween	3
🎄	Christmas tree	christmas tree	3
🎆	fireworks	fireworks festival celebration	3
🎇	sparkler	sparkler	3
🧨	firecracker	firecracker	3
✨	sparkles	sparkles shiny sparkle stars	3
🎈	balloon	balloon party birthday	3
🎉	party popper	party popper tada hooray	3
🎊	confetti ball	confetti ball	3
🎋	tanabata tree	tanabata tree	3
🎍	pine decoration	pine decoration bamboo	3
🎎	Japanese dolls	japanese dolls	3
🎏	carp streamer	carp streamer flags	3
🎐	wind chime	wind chime	3
🎑	moon viewing ceremony	moon viewing ceremony rice scene	3
🧧	red envelope	red envelope	3
🎀	ribbon	ribbon	3
🎁	wrapped gift	wrapped gift present birthday christmas	3
🎗️	reminder ribbon	reminder ribbon	3
🎟️	admission tickets	admission tickets	3
🎫	ticket	ticket	3
🎖️	military medal	military medal	3
🏆	trophy	trophy award contest winner	3
🏅	sports medal	sports medal gold winner	3
🥇	1st place medal	1st place medal gold	3
🥈	2nd place medal	2nd place medal silver	3
🥉	3rd place medal	3rd place medal bronze	3
⚽	soccer ball	soccer ball sports	3
⚾	baseball	baseball sports	3
🥎	softball	softball	3
🏀	basketball	basketball sports	3
🏐	volleyball	volleyball	3
🏈	american football	american football sports	3
🏉	rugby football	rugby football	3
🎾	tennis	tennis sports	3
🥏	flying disc	flying disc	3
🎳	bowling	bowling	3
🏏	cricket game	cricket game	3
🏑	field hockey	field hockey	3
🏒	ice hockey	ice hockey	3
🥍	lacrosse	lacrosse	3
🏓	ping pong	ping pong	3
🏸	badminton	badminton	3
🥊	boxing glove	boxing glove	3
🥋	martial arts uniform	martial arts uniform	3
🥅	goal net	goal net	3
⛳	flag in hole	flag in hole golf	3
⛸️	ice skate	ice skate skating	3
🎣	fishing pole	fishing pole and fish	3
🤿	diving mask	diving mask	3
🎽	running shirt	running shirt with sash marathon	3
🎿	skis	skis ski	3
🛷	sled	sled	3
🥌	curling stone	curling stone	3
🎯	bullseye	bullseye dart target	3
🪀	yo-yo	yo	3
🪁	kite	kite	3
🔫	water pistol	water pistol gun shoot weapon	3
🎱	pool 8 ball	pool 8 ball 8ball billiards	3
🔮	crystal ball	crystal ball fortune	3
🪄	magic wand	magic wand	3
🎮	video game	video game play controller console	3
🕹️	joystick	joystick	3
🎰	slot machine	slot machine	3
🎲	game die	game die dice gambling	3
🧩	puzzle piece	puzzle piece jigsaw	3
🧸	teddy bear	teddy bear	3
🪅	piñata	pi ata pinata	3
🪩	mirror ball	mirror ball disco party	3
🪆	nesting dolls	nesting dolls	3
♠️	spade suit	spade suit spades	3
♥️	heart suit	heart suit hearts	3
♦️	diamond suit	diamond suit diamonds	3
♣️	club suit	club suit clubs	3
♟️	chess pawn	chess pawn	3
🃏	joker	joker black	3
🀄	mahjong red dragon	mahjong red dragon	3
🎴	flower playing cards	flower playing cards	3
🎭	performing arts	performing arts theater drama	3
🖼️	framed picture	framed picture	3
🎨	artist palette	artist palette art design paint	3
🧵	thread	thread	3
🪡	sewing needle	sewing needle	3
🧶	yarn	yarn	3
🪢	knot	knot	3
👓	glasses	glasses eyeglasses	5
🕶️	sunglasses	sunglasses dark	5
🥽	goggles	goggles	5
🥼	lab coat	lab coat	5
🦺	safety vest	safety vest	5
👔	necktie	necktie shirt formal	5
👕	t-shirt	t shirt tshirt	5
👖	jeans	jeans pants	5
🧣	scarf	scarf	5
🧤	gloves	gloves	5
🧥	coat	coat	5
🧦	socks	socks	5
👗	dress	dress	5
👘	kimono	kimono	5
🥻	sari	sari	5
🩱	one-piece swimsuit	one piece swimsuit	5
🩲	briefs	briefs swim brief	5
🩳	shorts	shorts	5
👙	bikini	bikini beach	5
👚	woman’s clothes	woman s clothes womans	5
🪭	folding hand fan	folding hand fan sensu	5
👛	purse	purse	5
👜	handbag	handbag bag	5
👝	clutch bag	clutch bag pouch	5
🛍️	shopping bags	shopping bags	5
🎒	backpack	backpack school satchel	5
🩴	thong sandal	thong sandal	5
👞	man’s shoe	man s shoe mans	5
👟	running shoe	running shoe athletic sneaker sport	5
🥾	hiking boot	hiking boot	5
🥿	flat shoe	flat shoe	5
👠	high-heeled shoe	high heeled shoe heel	5
👡	woman’s sandal	woman s sandal shoe	5
🩰	ballet shoes	ballet shoes	5
👢	woman’s boot	woman s boot	5
🪮	hair pick	hair pick	5
👑	crown	crown king queen royal	5
👒	woman’s hat	woman s hat womans	5
🎩	top hat	top hat tophat classy	5
🎓	graduation cap	graduation cap mortar board education college university	5
🧢	billed cap	billed cap	5
🪖	military helmet	military helmet	5
⛑️	rescue worker’s helmet	rescue worker s helmet	5
📿	prayer beads	prayer beads	5
💄	lipstick	lipstick makeup	5
💍	ring	ring wedding marriage engaged	5
💎	gem stone	gem stone diamond	5
🔇	muted speaker	muted speaker mute sound volume	5
🔈	speaker low volume	speaker low volume	5
🔉	speaker medium volume	speaker medium volume sound	5
🔊	speaker high volume	speaker high volume loud sound	5
📢	loudspeaker	loudspeaker announcement	5
📣	megaphone	megaphone mega	5
📯	postal horn	postal horn	5
🔔	bell	bell sound notification	5
🔕	bell with slash	bell with slash no volume off	5
🎼	musical score	musical score	5
🎵	musical note	musical note	5
🎶	musical notes	musical notes music	5
🎙️	studio microphone	studio microphone podcast	5
🎚️	level slider	level slider	5
🎛️	control knobs	control knobs	5
🎤	microphone	microphone sing	5
🎧	headphone	headphone headphones music earphones	5
📻	radio	radio podcast	5
🎷	saxophone	saxophone	5
🪗	accordion	accordion	5
🎸	guitar	guitar rock	5
🎹	musical keyboard	musical keyboard piano	5
🎺	trumpet	trumpet	5
🎻	violin	violin	5
🪕	banjo	banjo	5
🥁	drum	drum	5
🪘	long drum	long drum	5
🪇	maracas	maracas shaker	5
🪈	flute	flute recorder	5
📱	mobile phone	mobile phone iphone smartphone	5
📲	mobile phone with arrow	mobile phone with arrow calling call incoming	5
☎️	telephone	telephone phone	5
📞	telephone receiver	telephone receiver phone call	5
📟	pager	pager	5
📠	fax machine	fax machine	5
🔋	battery	battery power	5
🪫	low battery	low battery	5
🔌	electric plug	electric plug	5
💻	laptop	laptop computer desktop screen	5
🖥️	desktop computer	desktop computer	5
🖨️	printer	printer	5
⌨️	keyboard	keyboard	5
🖱️	computer mouse	computer mouse	5
🖲️	trackball	trackball	5
💽	computer disk	computer disk minidisc	5
💾	floppy disk	floppy disk save	5
💿	optical disk	optical disk cd	5
📀	dvd	dvd	5
🧮	abacus	abacus	5
🎥	movie camera	movie camera film video	5
🎞️	film frames	film frames strip	5
📽️	film projector	film projector	5
🎬	clapper board	clapper board film	5
📺	television	television tv	5
📷	camera	camera photo	5
📸	camera with flash	camera with flash photo	5
📹	video camera	video camera	5
📼	videocassette	videocassette vhs	5
🔍	magnifying glass tilted left	magnifying glass tilted left mag search zoom	5
🔎	magnifying glass tilted right	magnifying glass tilted right mag	5
🕯️	candle	candle	5
💡	light bulb	light bulb idea	5
🔦	flashlight	flashlight	5
🏮	red paper lantern	red paper lantern izakaya	5
🪔	diya lamp	diya lamp	5
📔	notebook with decorative cover	notebook with decorative cover	5
📕	closed book	closed book	5
📖	open book	open book	5
📗	green book	green book	5
📘	blue book	blue book	5
📙	orange book	orange book	5
📚	books	books library	5
📓	notebook	notebook	5
📒	ledger	ledger	5
📃	page with curl	page with curl	5
📜	scroll	scroll document	5
📄	page facing up	page facing up document	5
📰	newspaper	newspaper press	5
🗞️	rolled-up newspaper	rolled up newspaper roll press	5
📑	bookmark tabs	bookmark tabs	5
🔖	bookmark	bookmark	5
🏷️	label	label tag	5
💰	money bag	money bag moneybag dollar cream	5
🪙	coin	coin	5
💴	yen banknote	yen banknote	5
💵	dollar banknote	dollar banknote money	5
💶	euro banknote	euro banknote	5
💷	pound banknote	pound banknote	5
💸	money with wings	money with wings dollar	5
💳	credit card	credit card subscription	5
🧾	receipt	receipt	5
💹	chart increasing with yen	chart increasing with yen	5
✉️	envelope	envelope letter email	5
📧	e-mail	e mail email	5
📨	incoming envelope	incoming envelope	5
📩	envelope with arrow	envelope with arrow	5
📤	outbox tray	outbox tray	5
📥	inbox tray	inbox tray	5
📦	package	package shipping	5
📫	closed mailbox with raised flag	closed mailbox with raised flag	5
📪	closed mailbox with lowered flag	closed mailbox with lowered flag	5
📬	open mailbox with raised flag	open mailbox with raised flag mail	5
📭	open mailbox with lowered flag	open mailbox with lowered flag no mail	5
📮	postbox	postbox	5
🗳️	ballot box with ballot	ballot box with	5
✏️	pencil	pencil pencil2	5
✒️	black nib	black nib	5
🖋️	fountain pen	fountain pen	5
🖊️	pen	pen	5
🖌️	paintbrush	paintbrush	5
🖍️	crayon	crayon	5
📝	memo	memo pencil document note	5
💼	briefcase	briefcase business	5
📁	file folder	file folder directory	5
📂	open file folder	open file folder	5
🗂️	card index dividers	card index dividers	5
📅	calendar	calendar date schedule	5
📆	tear-off calendar	tear off calendar schedule	5
🗒️	spiral notepad	spiral notepad	5
🗓️	spiral calendar	spiral calendar	5
📇	card index	card index	5
📈	chart increasing	chart increasing with upwards trend graph metrics	5
📉	chart decreasing	chart decreasing with downwards trend graph metrics	5
📊	bar chart	bar chart stats metrics	5
📋	clipboard	clipboard	5
📌	pushpin	pushpin location	5
📍	round pushpin	round pushpin location	5
📎	paperclip	paperclip	5
🖇️	linked paperclips	linked paperclips	5
📏	straight ruler	straight ruler	5
📐	triangular ruler	triangular ruler	5
✂️	scissors	scissors cut	5
🗃️	card file box	card file box	5
🗄️	file cabinet	file cabinet	5
🗑️	wastebasket	wastebasket trash	5
🔒	locked	locked lock security private	5
🔓	unlocked	unlocked unlock security	5
🔏	locked with pen	locked with pen lock ink	5
🔐	locked with key	locked with key closed lock security	5
🔑	key	key lock password	5
🗝️	old key	old key	5
🔨	hammer	hammer tool	5
🪓	axe	axe	5
⛏️	pick	pick	5
⚒️	hammer and pick	hammer and pick	5
🛠️	hammer and wrench	hammer and wrench	5
🗡️	dagger	dagger	5
⚔️	crossed swords	crossed swords	5
💣	bomb	bomb boom	5
🪃	boomerang	boomerang	5
🏹	bow and arrow	bow and arrow archery	5
🛡️	shield	shield	5
🪚	carpentry saw	carpentry saw	5
🔧	wrench	wrench tool	5
🪛	screwdriver	screwdriver	5
🔩	nut and bolt	nut and bolt	5
⚙️	gear	gear	5
🗜️	clamp	clamp	5
⚖️	balance scale	balance scale	5
🦯	white cane	white cane probing	5
🔗	link	link	5
⛓️	chains	chains	5
🪝	hook	hook	5
🧰	toolbox	toolbox	5
🧲	magnet	magnet	5
🪜	ladder	ladder	5
⚗️	alembic	alembic	5
🧪	test tube	test tube	5
🧫	petri dish	petri dish	5
🧬	dna	dna	5
🔬	microscope	microscope science laboratory investigate	5
🔭	telescope	telescope	5
📡	satellite antenna	satellite antenna signal	5
💉	syringe	syringe health hospital needle	5
🩸	drop of blood	drop of blood	5
💊	pill	pill health medicine	5
🩹	adhesive bandage	adhesive bandage	5
🩼	crutch	crutch	5
🩺	stethoscope	stethoscope	5
🩻	x-ray	x ray	5
🚪	door	door	5
🛗	elevator	elevator	5
🪞	mirror	mirror	5
🪟	window	window	5
🛏️	bed	bed	5
🛋️	couch and lamp	couch and lamp	5
🪑	chair	chair	5
🚽	toilet	toilet wc	5
🪠	plunger	plunger	5
🚿	shower	shower bath	5
🛁	bathtub	bathtub	5
🪤	mouse trap	mouse trap	5
🪒	razor	razor	5
🧴	lotion bottle	lotion bottle	5
🧷	safety pin	safety pin	5
🧹	broom	broom	5
🧺	basket	basket	5
🧻	roll of paper	roll of paper toilet	5
🪣	bucket	bucket	5
🧼	soap	soap	5
🫧	bubbles	bubbles	5
🪥	toothbrush	toothbrush	5
🧽	sponge	sponge	5
🧯	fire extinguisher	fire extinguisher	5
🛒	shopping cart	shopping cart	5
🚬	cigarette	cigarette smoking	5
⚰️	coffin	coffin funeral	5
🪦	headstone	headstone	5
⚱️	funeral urn	funeral urn	5
🧿	nazar amulet	nazar amulet	5
🪬	hamsa	hamsa	5
🗿	moai	moai moyai stone	5
🪧	placard	placard	5
🪪	identification card	identification card	5
🏧	ATM sign	atm sign	6
🚮	litter in bin sign	litter in bin sign put its place	6
🚰	potable water	potable water	6
♿	wheelchair symbol	wheelchair symbol accessibility	6
🚹	men’s room	men s room mens	6
🚺	women’s room	women s room womens	6
🚻	restroom	restroom toilet	6
🚼	baby symbol	baby symbol	6
🚾	water closet	water closet wc toilet restroom	6
🛂	passport control	passport control	6
🛃	customs	customs	6
🛄	baggage claim	baggage claim airport	6
🛅	left luggage	left luggage	6
⚠️	warning	warning wip	6
🚸	children crossing	children crossing	6
⛔	no entry	no entry limit	6
🚫	prohibited	prohibited no entry sign block forbidden	6
🚳	no bicycles	no bicycles	6
🚭	no smoking	no smoking	6
🚯	no littering	no littering do not litter	6
🚱	non-potable water	non potable water	6
🚷	no pedestrians	no pedestrians	6
📵	no mobile phones	no mobile phones	6
🔞	no one under eighteen	no one under eighteen underage	6
☢️	radioactive	radioactive	6
☣️	biohazard	biohazard	6
⬆️	up arrow	up arrow	6
↗️	up-right arrow	up right arrow upper	6
➡️	right arrow	right arrow	6
↘️	down-right arrow	down right arrow lower	6
⬇️	down arrow	down arrow	6
↙️	down-left arrow	down left arrow lower	6
⬅️	left arrow	left arrow	6
↖️	up-left arrow	up left arrow upper	6
↕️	up-down arrow	up down arrow	6
↔️	left-right arrow	left right arrow	6
↩️	right arrow curving left	right arrow curving left leftwards with hook return	6
↪️	left arrow curving right	left arrow curving right hook	6
⤴️	right arrow curving up	right arrow curving up heading	6
⤵️	right arrow curving down	right arrow curving down heading	6
🔃	clockwise vertical arrows	clockwise vertical arrows	6
🔄	counterclockwise arrows button	counterclockwise arrows button sync	6
🔙	BACK arrow	back arrow	6
🔚	END arrow	end arrow	6
🔛	ON! arrow	on arrow	6
🔜	SOON arrow	soon arrow	6
🔝	TOP arrow	top arrow	6
🛐	place of worship	place of worship	6
⚛️	atom symbol	atom symbol	6
🕉️	om	om	6
✡️	star of David	star of david	6
☸️	wheel of dharma	wheel of dharma	6
☯️	yin yang	yin yang	6
✝️	latin cross	latin cross	6
☦️	orthodox cross	orthodox cross	6
☪️	star and crescent	star and crescent	6
☮️	peace symbol	peace symbol	6
🕎	menorah	menorah	6
🔯	dotted six-pointed star	dotted six pointed star	6
🪯	khanda	khanda	6
♈	Aries	aries	6
♉	Taurus	taurus	6
♊	Gemini	gemini	6
♋	Cancer	cancer	6
♌	Leo	leo	6
♍	Virgo	virgo	6
♎	Libra	libra	6
♏	Scorpio	scorpio scorpius	6
♐	Sagittarius	sagittarius	6
♑	Capricorn	capricorn	6
♒	Aquarius	aquarius	6
♓	Pisces	pisces	6
⛎	Ophiuchus	ophiuchus	6
🔀	shuffle tracks button	shuffle tracks button twisted rightwards arrows	6
🔁	repeat button	repeat button loop	6
🔂	repeat single button	repeat single button one	6
▶️	play button	play button arrow forward	6
⏩	fast-forward button	fast forward button	6
⏭️	next track button	next track button	6
⏯️	play or pause button	play or pause button	6
◀️	reverse button	reverse button arrow backward	6
⏪	fast reverse button	fast reverse button rewind	6
⏮️	last track button	last track button previous	6
🔼	upwards button	upwards button arrow up small	6
⏫	fast up button	fast up button arrow double	6
🔽	downwards button	downwards button arrow down small	6
⏬	fast down button	fast down button arrow double	6
⏸️	pause button	pause button	6
⏹️	stop button	stop button	6
⏺️	record button	record button	6
⏏️	eject button	eject button	6
🎦	cinema	cinema film movie	6
🔅	dim button	dim button low brightness	6
🔆	bright button	bright button high brightness	6
📶	antenna bars	antenna bars signal strength wifi	6
🛜	wireless	wireless wifi	6
📳	vibration mode	vibration mode	6
📴	mobile phone off	mobile phone off mute	6
♀️	female sign	female sign	6
♂️	male sign	male sign	6
⚧️	transgender symbol	transgender symbol	6
✖️	multiply	multiply heavy multiplication x	6
➕	plus	plus heavy sign	6
➖	minus	minus heavy sign	6
➗	divide	divide heavy division sign	6
🟰	heavy equals sign	heavy equals sign	6
♾️	infinity	infinity	6
‼️	double exclamation mark	double exclamation mark bangbang	6
⁉️	exclamation question mark	exclamation question mark interrobang	6
❓	red question mark	red question mark confused	6
❔	white question mark	white question mark grey	6
❕	white exclamation mark	white exclamation mark grey	6
❗	red exclamation mark	red exclamation mark heavy bang	6
〰️	wavy dash	wavy dash	6
💱	currency exchange	currency exchange	6
💲	heavy dollar sign	heavy dollar sign	6
⚕️	medical symbol	medical symbol	6
♻️	recycling symbol	recycling symbol recycle environment green	6
⚜️	fleur-de-lis	fleur de lis	6
🔱	trident emblem	trident emblem	6
📛	name badge	name badge	6
🔰	Japanese symbol for beginner	japanese symbol for beginner	6
⭕	hollow red circle	hollow red circle o	6
✅	check mark button	check mark button white	6
☑️	check box with check	check box with ballot	6
✔️	check mark	check mark heavy	6
❌	cross mark	cross mark x	6
❎	cross mark button	cross mark button negative squared	6
➰	curly loop	curly loop	6
➿	double curly loop	double curly loop	6
〽️	part alternation mark	part alternation mark	6
✳️	eight-spoked asterisk	eight spoked asterisk	6
✴️	eight-pointed star	eight pointed star black	6
❇️	sparkle	sparkle	6
©️	copyright	copyright	6
®️	registered	registered	6
™️	trade mark	trade mark tm trademark	6
#️⃣	keycap: #	keycap hash number	6
*️⃣	keycap: *	keycap asterisk	6
0️⃣	keycap: 0	keycap 0 zero	6
1️⃣	keycap: 1	keycap 1 one	6
2️⃣	keycap: 2	keycap 2 two	6
3️⃣	keycap: 3	keycap 3 three	6
4️⃣	keycap: 4	keycap 4 four	6
5️⃣	keycap: 5	keycap 5 five	6
6️⃣	keycap: 6	keycap 6 six	6
7️⃣	keycap: 7	keycap 7 seven	6
8️⃣	keycap: 8	keycap 8 eight	6
9️⃣	keycap: 9	keycap 9 nine	6
🔟	keycap: 10	keycap 10 ten	6
🔠	input latin uppercase	input latin uppercase capital abcd letters	6
🔡	input latin lowercase	input latin lowercase abcd	6
🔢	input numbers	input numbers 1234	6
🔣	input symbols	input symbols	6
🔤	input latin letters	input latin letters abc alphabet	6
🅰️	A button (blood type)	a button blood type	6
🆎	AB button (blood type)	ab button blood type	6
🅱️	B button (blood type)	b button blood type	6
🆑	CL button	cl button	6
🆒	COOL button	cool button	6
🆓	FREE button	free button	6
ℹ️	information	information source	6
🆔	ID button	id button	6
Ⓜ️	circled M	circled m	6
🆕	NEW button	new button fresh	6
🆖	NG button	ng button	6
🅾️	O button (blood type)	o button blood type o2	6
🆗	OK button	ok button yes	6
🅿️	P button	p button parking	6
🆘	SOS button	sos button help emergency	6
🆙	UP! button	up button	6
🆚	VS button	vs button	6
🈁	Japanese “here” button	japanese here button koko	6
🈂️	Japanese “service charge” button	japanese service charge button sa	6
🈷️	Japanese “monthly amount” button	japanese monthly amount button u6708	6
🈶	Japanese “not free of charge” button	japanese not free of charge button u6709	6
🈯	Japanese “reserved” button	japanese reserved button u6307	6
🉐	Japanese “bargain” button	japanese bargain button ideograph advantage	6
🈹	Japanese “discount” button	japanese discount button u5272	6
🈚	Japanese “free of charge” button	japanese free of charge button u7121	6
🈲	Japanese “prohibited” button	japanese prohibited button u7981	6
🉑	Japanese “acceptable” button	japanese acceptable button accept	6
🈸	Japanese “application” button	japanese application button u7533	6
🈴	Japanese “passing grade” button	japanese passing grade button u5408	6
🈳	Japanese “vacancy” button	japanese vacancy button u7a7a	6
㊗️	Japanese “congratulations” button	japanese congratulations button	6
㊙️	Japanese “secret” button	japanese secret button	6
🈺	Japanese “open for business” button	japanese open for business button u55b6	6
🈵	Japanese “no vacancy” button	japanese no vacancy button u6e80	6
🔴	red circle	red circle	6
🟠	orange circle	orange circle	6
🟡	yellow circle	yellow circle	6
🟢	green circle	green circle	6
🔵	blue circle	blue circle large	6
🟣	purple circle	purple circle	6
🟤	brown circle	brown circle	6
⚫	black circle	black circle	6
⚪	white circle	white circle	6
🟥	red square	red square	6
🟧	orange square	orange square	6
🟨	yellow square	yellow square	6
🟩	green square	green square	6
🟦	blue square	blue square	6
🟪	purple square	purple square	6
🟫	brown square	brown square	6
⬛	black large square	black large square	6
⬜	white large square	white large square	6
◼️	black medium square	black medium square	6
◻️	white medium square	white medium square	6
◾	black medium-small square	black medium small square	6
◽	white medium-small square	white medium small square	6
▪️	black small square	black small square	6
▫️	white small square	white small square	6
🔶	large orange diamond	large orange diamond	6
🔷	large blue diamond	large blue diamond	6
🔸	small orange diamond	small orange diamond	6
🔹	small blue diamond	small blue diamond	6
🔺	red triangle pointed up	red triangle pointed up small	6
🔻	red triangle pointed down	red triangle pointed down small	6
💠	diamond with a dot	diamond with a dot shape inside	6
🔘	radio button	radio button	6
🔳	white square button	white square button	6
🔲	black square button	black square button	6
🏁	chequered flag	chequered flag checkered milestone finish	7
🚩	triangular flag	triangular flag on post	7
🎌	crossed flags	crossed flags	7
🏴	black flag	black flag	7
🏳️	white flag	white flag	7
🏳️‍🌈	rainbow flag	rainbow flag pride	7
🏳️‍⚧️	transgender flag	transgender flag	7
🏴‍☠️	pirate flag	pirate flag	7
🇦🇨	flag: Ascension Island	flag ascension island	7
🇦🇩	flag: Andorra	flag andorra	7
🇦🇪	flag: United Arab Emirates	flag united arab emirates	7
🇦🇫	flag: Afghanistan	flag afghanistan	7
🇦🇬	flag: Antigua & Barbuda	flag antigua barbuda	7
🇦🇮	flag: Anguilla	flag anguilla	7
🇦🇱	flag: Albania	flag albania	7
🇦🇲	flag: Armenia	flag armenia	7
🇦🇴	flag: Angola	flag angola	7
🇦🇶	flag: Antarctica	flag antarctica	7
🇦🇷	flag: Argentina	flag argentina	7
🇦🇸	flag: American Samoa	flag american samoa	7
🇦🇹	flag: Austria	flag austria	7
🇦🇺	flag: Australia	flag australia	7
🇦🇼	flag: Aruba	flag aruba	7
🇦🇽	flag: Åland Islands	flag land islands aland	7
🇦🇿	flag: Azerbaijan	flag azerbaijan	7
🇧🇦	flag: Bosnia & Herzegovina	flag bosnia herzegovina	7
🇧🇧	flag: Barbados	flag barbados	7
🇧🇩	flag: Bangladesh	flag bangladesh	7
🇧🇪	flag: Belgium	flag belgium	7
🇧🇫	flag: Burkina Faso	flag burkina faso	7
🇧🇬	flag: Bulgaria	flag bulgaria	7
🇧🇭	flag: Bahrain	flag bahrain	7
🇧🇮	flag: Burundi	flag burundi	7
🇧🇯	flag: Benin	flag benin	7
🇧🇱	flag: St. Barthélemy	flag st barth lemy barthelemy	7
🇧🇲	flag: Bermuda	flag bermuda	7
🇧🇳	flag: Brunei	flag brunei	7
🇧🇴	flag: Bolivia	flag bolivia	7
🇧🇶	flag: Caribbean Netherlands	flag caribbean netherlands	7
🇧🇷	flag: Brazil	flag brazil	7
🇧🇸	flag: Bahamas	flag bahamas	7
🇧🇹	flag: Bhutan	flag bhutan	7
🇧🇻	flag: Bouvet Island	flag bouvet island	7
🇧🇼	flag: Botswana	flag botswana	7
🇧🇾	flag: Belarus	flag belarus	7
🇧🇿	flag: Belize	flag belize	7
🇨🇦	flag: Canada	flag canada	7
🇨🇨	flag: Cocos (Keeling) Islands	flag cocos keeling islands	7
🇨🇩	flag: Congo - Kinshasa	flag congo kinshasa	7
🇨🇫	flag: Central African Republic	flag central african republic	7
🇨🇬	flag: Congo - Brazzaville	flag congo brazzaville	7
🇨🇭	flag: Switzerland	flag switzerland	7
🇨🇮	flag: Côte d’Ivoire	flag c te d ivoire cote divoire ivory	7
🇨🇰	flag: Cook Islands	flag cook islands	7
🇨🇱	flag: Chile	flag chile	7
🇨🇲	flag: Cameroon	flag cameroon	7
🇨🇳	flag: China	flag china cn	7
🇨🇴	flag: Colombia	flag colombia	7
🇨🇵	flag: Clipperton Island	flag clipperton island	7
🇨🇷	flag: Costa Rica	flag costa rica	7
🇨🇺	flag: Cuba	flag cuba	7
🇨🇻	flag: Cape Verde	flag cape verde	7
🇨🇼	flag: Curaçao	flag cura ao curacao	7
🇨🇽	flag: Christmas Island	flag christmas island	7
🇨🇾	flag: Cyprus	flag cyprus	7
🇨🇿	flag: Czechia	flag czechia czech republic	7
🇩🇪	flag: Germany	flag germany de	7
🇩🇬	flag: Diego Garcia	flag diego garcia	7
🇩🇯	flag: Djibouti	flag djibouti	7
🇩🇰	flag: Denmark	flag denmark	7
🇩🇲	flag: Dominica	flag dominica	7
🇩🇴	flag: Dominican Republic	flag dominican republic	7
🇩🇿	flag: Algeria	flag algeria	7
🇪🇦	flag: Ceuta & Melilla	flag ceuta melilla	7
🇪🇨	flag: Ecuador	flag ecuador	7
🇪🇪	flag: Estonia	flag estonia	7
🇪🇬	flag: Egypt	flag egypt	7
🇪🇭	flag: Western Sahara	flag western sahara	7
🇪🇷	flag: Eritrea	flag eritrea	7
🇪🇸	flag: Spain	flag spain es	7
🇪🇹	flag: Ethiopia	flag ethiopia	7
🇪🇺	flag: European Union	flag european union eu	7
🇫🇮	flag: Finland	flag finland	7
🇫🇯	flag: Fiji	flag fiji	7
🇫🇰	flag: Falkland Islands	flag falkland islands	7
🇫🇲	flag: Micronesia	flag micronesia	7
🇫🇴	flag: Faroe Islands	flag faroe islands	7
🇫🇷	flag: France	flag france fr french	7
🇬🇦	flag: Gabon	flag gabon	7
🇬🇧	flag: United Kingdom	flag united kingdom gb uk british	7
🇬🇩	flag: Grenada	flag grenada	7
🇬🇪	flag: Georgia	flag georgia	7
🇬🇫	flag: French Guiana	flag french guiana	7
🇬🇬	flag: Guernsey	flag guernsey	7
🇬🇭	flag: Ghana	flag ghana	7
🇬🇮	flag: Gibraltar	flag gibraltar	7
🇬🇱	flag: Greenland	flag greenland	7
🇬🇲	flag: Gambia	flag gambia	7
🇬🇳	flag: Guinea	flag guinea	7
🇬🇵	flag: Guadeloupe	flag guadeloupe	7
🇬🇶	flag: Equatorial Guinea	flag equatorial guinea	7
🇬🇷	flag: Greece	flag greece	7
🇬🇸	flag: South Georgia & South Sandwich Islands	flag south georgia sandwich islands	7
🇬🇹	flag: Guatemala	flag guatemala	7
🇬🇺	flag: Guam	flag guam	7
🇬🇼	flag: Guinea-Bissau	flag guinea bissau	7
🇬🇾	flag: Guyana	flag guyana	7
🇭🇰	flag: Hong Kong SAR China	flag hong kong sar china	7
🇭🇲	flag: Heard & McDonald Islands	flag heard mcdonald islands	7
🇭🇳	flag: Honduras	flag honduras	7
🇭🇷	flag: Croatia	flag croatia	7
🇭🇹	flag: Haiti	flag haiti	7
🇭🇺	flag: Hungary	flag hungary	7
🇮🇨	flag: Canary Islands	flag canary islands	7
🇮🇩	flag: Indonesia	flag indonesia	7
🇮🇪	flag: Ireland	flag ireland	7
🇮🇱	flag: Israel	flag israel	7
🇮🇲	flag: Isle of Man	flag isle of man	7
🇮🇳	flag: India	flag india	7
🇮🇴	flag: British Indian Ocean Territory	flag british indian ocean territory	7
🇮🇶	flag: Iraq	flag iraq	7
🇮🇷	flag: Iran	flag iran	7
🇮🇸	flag: Iceland	flag iceland	7
🇮🇹	flag: Italy	flag italy it	7
🇯🇪	flag: Jersey	flag jersey	7
🇯🇲	flag: Jamaica	flag jamaica	7
🇯🇴	flag: Jordan	flag jordan	7
🇯🇵	flag: Japan	flag japan jp	7
🇰🇪	flag: Kenya	flag kenya	7
🇰🇬	flag: Kyrgyzstan	flag kyrgyzstan	7
🇰🇭	flag: Cambodia	flag cambodia	7
🇰🇮	flag: Kiribati	flag kiribati	7
🇰🇲	flag: Comoros	flag comoros	7
🇰🇳	flag: St. Kitts & Nevis	flag st kitts nevis	7
🇰🇵	flag: North Korea	flag north korea	7
🇰🇷	flag: South Korea	flag south korea kr	7
🇰🇼	flag: Kuwait	flag kuwait	7
🇰🇾	flag: Cayman Islands	flag cayman islands	7
🇰🇿	flag: Kazakhstan	flag kazakhstan	7
🇱🇦	flag: Laos	flag laos	7
🇱🇧	flag: Lebanon	flag lebanon	7
🇱🇨	flag: St. Lucia	flag st lucia	7
🇱🇮	flag: Liechtenstein	flag liechtenstein	7
🇱🇰	flag: Sri Lanka	flag sri lanka	7
🇱🇷	flag: Liberia	flag liberia	7
🇱🇸	flag: Lesotho	flag lesotho	7
🇱🇹	flag: Lithuania	flag lithuania	7
🇱🇺	flag: Luxembourg	flag luxembourg	7
🇱🇻	flag: Latvia	flag latvia	7
🇱🇾	flag: Libya	flag libya	7
🇲🇦	flag: Morocco	flag morocco	7
🇲🇨	flag: Monaco	flag monaco	7
🇲🇩	flag: Moldova	flag moldova	7
🇲🇪	flag: Montenegro	flag montenegro	7
🇲🇫	flag: St. Martin	flag st martin	7
🇲🇬	flag: Madagascar	flag madagascar	7
🇲🇭	flag: Marshall Islands	flag marshall islands	7
🇲🇰	flag: North Macedonia	flag north macedonia	7
🇲🇱	flag: Mali	flag mali	7
🇲🇲	flag: Myanmar (Burma)	flag myanmar burma	7
🇲🇳	flag: Mongolia	flag mongolia	7
🇲🇴	flag: Macao SAR China	flag macao sar china macau	7
🇲🇵	flag: Northern Mariana Islands	flag northern mariana islands	7
🇲🇶	flag: Martinique	flag martinique	7
🇲🇷	flag: Mauritania	flag mauritania	7
🇲🇸	flag: Montserrat	flag montserrat	7
🇲🇹	flag: Malta	flag malta	7
🇲🇺	flag: Mauritius	flag mauritius	7
🇲🇻	flag: Maldives	flag maldives	7
🇲🇼	flag: Malawi	flag malawi	7
🇲🇽	flag: Mexico	flag mexico	7
🇲🇾	flag: Malaysia	flag malaysia	7
🇲🇿	flag: Mozambique	flag mozambique	7
🇳🇦	flag: Namibia	flag namibia	7
🇳🇨	flag: New Caledonia	flag new caledonia	7
🇳🇪	flag: Niger	flag niger	7
🇳🇫	flag: Norfolk Island	flag norfolk island	7
🇳🇬	flag: Nigeria	flag nigeria	7
🇳🇮	flag: Nicaragua	flag nicaragua	7
🇳🇱	flag: Netherlands	flag netherlands	7
🇳🇴	flag: Norway	flag norway	7
🇳🇵	flag: Nepal	flag nepal	7
🇳🇷	flag: Nauru	flag nauru	7
🇳🇺	flag: Niue	flag niue	7
🇳🇿	flag: New Zealand	flag new zealand	7
🇴🇲	flag: Oman	flag oman	7
🇵🇦	flag: Panama	flag panama	7
🇵🇪	flag: Peru	flag peru	7
🇵🇫	flag: French Polynesia	flag french polynesia	7
🇵🇬	flag: Papua New Guinea	flag papua new guinea	7
🇵🇭	flag: Philippines	flag philippines	7
🇵🇰	flag: Pakistan	flag pakistan	7
🇵🇱	flag: Poland	flag poland	7
🇵🇲	flag: St. Pierre & Miquelon	flag st pierre miquelon	7
🇵🇳	flag: Pitcairn Islands	flag pitcairn islands	7
🇵🇷	flag: Puerto Rico	flag puerto rico	7
🇵🇸	flag: Palestinian Territories	flag palestinian territories	7
🇵🇹	flag: Portugal	flag portugal	7
🇵🇼	flag: Palau	flag palau	7
🇵🇾	flag: Paraguay	flag paraguay	7
🇶🇦	flag: Qatar	flag qatar	7
🇷🇪	flag: Réunion	flag r union reunion	7
🇷🇴	flag: Romania	flag romania	7
🇷🇸	flag: Serbia	flag serbia	7
🇷🇺	flag: Russia	flag russia ru	7
🇷🇼	flag: Rwanda	flag rwanda	7
🇸🇦	flag: Saudi Arabia	flag saudi arabia	7
🇸🇧	flag: Solomon Islands	flag solomon islands	7
🇸🇨	flag: Seychelles	flag seychelles	7
🇸🇩	flag: Sudan	flag sudan	7
🇸🇪	flag: Sweden	flag sweden	7
🇸🇬	flag: Singapore	flag singapore	7
🇸🇭	flag: St. Helena	flag st helena	7
🇸🇮	flag: Slovenia	flag slovenia	7
🇸🇯	flag: Svalbard & Jan Mayen	flag svalbard jan mayen	7
🇸🇰	flag: Slovakia	flag slovakia	7
🇸🇱	flag: Sierra Leone	flag sierra leone	7
🇸🇲	flag: San Marino	flag san marino	7
🇸🇳	flag: Senegal	flag senegal	7
🇸🇴	flag: Somalia	flag somalia	7
🇸🇷	flag: Suriname	flag suriname	7
🇸🇸	flag: South Sudan	flag south sudan	7
🇸🇹	flag: São Tomé & Príncipe	flag s o tom pr ncipe sao tome principe	7
🇸🇻	flag: El Salvador	flag el salvador	7
🇸🇽	flag: Sint Maarten	flag sint maarten	7
🇸🇾	flag: Syria	flag syria	7
🇸🇿	flag: Eswatini	flag eswatini swaziland	7
🇹🇦	flag: Tristan da Cunha	flag tristan da cunha	7
🇹🇨	flag: Turks & Caicos Islands	flag turks caicos islands	7
🇹🇩	flag: Chad	flag chad	7
🇹🇫	flag: French Southern Territories	flag french southern territories	7
🇹🇬	flag: Togo	flag togo	7
🇹🇭	flag: Thailand	flag thailand	7
🇹🇯	flag: Tajikistan	flag tajikistan	7
🇹🇰	flag: Tokelau	flag tokelau	7
🇹🇱	flag: Timor-Leste	flag timor leste	7
🇹🇲	flag: Turkmenistan	flag turkmenistan	7
🇹🇳	flag: Tunisia	flag tunisia	7
🇹🇴	flag: Tonga	flag tonga	7
🇹🇷	flag: Turkey	flag turkey tr	7
🇹🇹	flag: Trinidad & Tobago	flag trinidad tobago	7
🇹🇻	flag: Tuvalu	flag tuvalu	7
🇹🇼	flag: Taiwan	flag taiwan	7
🇹🇿	flag: Tanzania	flag tanzania	7
🇺🇦	flag: Ukraine	flag ukraine	7
🇺🇬	flag: Uganda	flag uganda	7
🇺🇲	flag: U.S. Outlying Islands	flag u s outlying islands us	7
🇺🇳	flag: United Nations	flag united nations	7
🇺🇸	flag: United States	flag united states us america	7
🇺🇾	flag: Uruguay	flag uruguay	7
🇺🇿	flag: Uzbekistan	flag uzbekistan	7
🇻🇦	flag: Vatican City	flag vatican city	7
🇻🇨	flag: St. Vincent & Grenadines	flag st vincent grenadines	7
🇻🇪	flag: Venezuela	flag venezuela	7
🇻🇬	flag: British Virgin Islands	flag british virgin islands	7
🇻🇮	flag: U.S. Virgin Islands	flag u s virgin islands us	7
🇻🇳	flag: Vietnam	flag vietnam	7
🇻🇺	flag: Vanuatu	flag vanuatu	7
🇼🇫	flag: Wallis & Futuna	flag wallis futuna	7
🇼🇸	flag: Samoa	flag samoa	7
🇽🇰	flag: Kosovo	flag kosovo	7
🇾🇪	flag: Yemen	flag yemen	7
🇾🇹	flag: Mayotte	flag mayotte	7
🇿🇦	flag: South Africa	flag south africa	7
🇿🇲	flag: Zambia	flag zambia	7
🇿🇼	flag: Zimbabwe	flag zimbabwe	7
🏴󠁧󠁢󠁥󠁮󠁧󠁿	flag: England	flag england	7
🏴󠁧󠁢󠁳󠁣󠁴󠁿	flag: Scotland	flag scotland	7
🏴󠁧󠁢󠁷󠁬󠁳󠁿	flag: Wales	flag wales	7
"""

    private static let cached: [Item] = packed.split(separator: "\n").compactMap(parse(line:))

    static var all: [Item] { cached }

    static func items(in category: Category) -> [Item] {
        cached.filter { $0.category == category }
    }

    static func search(query: String) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokens = trimmed.lowercased().split { $0.isWhitespace || $0 == "_" }.map(String.init)
        return cached.filter { item in
            if item.glyph == trimmed { return true }
            let hay = (item.name + " " + item.keywords).lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
    }

    private static func parse(line: Substring) -> Item? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 4, let cat = Int(parts[3]), let category = Category(rawValue: cat) else {
            return nil
        }
        let glyph = String(parts[0])
        guard !glyph.isEmpty else { return nil }
        return Item(glyph: glyph, name: String(parts[1]), keywords: String(parts[2]), category: category)
    }
}
