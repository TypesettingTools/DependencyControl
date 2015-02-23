local DependencyControl = require("l0.DependencyControl")
local version = DependencyControl{
    name = "ASSFoundation",
    version = "0.1.1",
    description = "General purpose ASS processing library",
    author = "line0",
    url = "http://github.com/TypesettingCartel/ASSFoundation",
    moduleName = "l0.ASSFoundation",
    feed = "https://raw.githubusercontent.com/TypesettingCartel/ASSFoundation/master/DependencyControl.json",
    {
        "l0.ASSFoundation.ClassFactory",
        "aegisub.re", "aegisub.util", "aegisub.unicode",
        {"l0.ASSFoundation.Common", version="0.1.1", url="https://github.com/TypesettingCartel/ASSFoundation",
         feed = "https://raw.githubusercontent.com/TypesettingCartel/ASSFoundation/master/DependencyControl.json"},
        {"a-mo.LineCollection", version="1.0.1", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Line", version="1.0.0", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Log", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        "ASSInspector.Inspector",
        {"YUtils", optional=true},
    }
}

local modules = {version:requireModules()}
local createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils = unpack(modules)
local ASS = require("l0.ASSFoundation.FoundationMethods")(unpack(modules))
local ASSFInstMeta = {__index = ASS}
local ASSFInstProxy = setmetatable({}, ASSFInstMeta)
local yutilsMissingMsg = version:checkOptionalModules("YUtils", true)

local function loadClass(name)
    return require("l0.ASSFoundation."..name)(ASS, ASSFInstProxy, yutilsMissingMsg, unpack(modules))
end

-- Base Classes
ASS.Base             = loadClass("Base")
ASS.Tag, ASS.Draw    = {}, {}
ASS.Tag.Base         = loadClass("Tag.Base")
ASS.Draw.DrawingBase = loadClass("Draw.DrawingBase")
ASS.Draw.CommandBase = loadClass("Draw.CommandBase")

-- Primitives
ASS.Number   = loadClass("Primitive.Number")
ASS.String   = loadClass("Primitive.String")
ASS.Point    = loadClass("Primitive.Point")
ASS.Time     = loadClass("Primitive.Time")
ASS.Duration = createASSClass("Duration", ASS.Time,   {"value"}, {"number"}, {positive=true})
ASS.Hex      = createASSClass("Hex",      ASS.Number, {"value"}, {"number"}, {range={0,255}, base=16, precision=0})

ASS.LineContents = loadClass("LineContents")
ASS.LineBounds   = loadClass("LineBounds")
ASS.TagList      = loadClass("TagList")

-- Sections
ASS.Section         = {}
ASS.Section.Text    = loadClass("Section.Text")
ASS.Section.Tag     = loadClass("Section.Tag")
ASS.Section.Comment = loadClass("Section.Comment")
ASS.Section.Drawing = loadClass("Section.Drawing")
table.mergeInto(ASS.Section, table.values(ASS.Section))

-- Tags
ASS.Tag.ClipRect  = loadClass("Tag.ClipRect")
ASS.Tag.ClipVect  = loadClass("Tag.ClipVect")
ASS.Tag.Color     = loadClass("Tag.Color")
ASS.Tag.Fade      = loadClass("Tag.Fade")
ASS.Tag.Indexed   = loadClass("Tag.Indexed")
ASS.Tag.Align     = loadClass("Tag.Align")
ASS.Tag.Move      = loadClass("Tag.Move")
ASS.Tag.String    = loadClass("Tag.String")
ASS.Tag.Transform = loadClass("Tag.Transform")
ASS.Tag.Toggle    = loadClass("Tag.Toggle")
ASS.Tag.Weight    = loadClass("Tag.Weight")
ASS.Tag.WrapStyle = createASSClass("Tag.WrapStyle", ASS.Tag.Indexed, {"value"}, {"number"}, {range={0,3}, default=0})
-- Unrecognized Tag
local UnknownTag = createASSClass("Tag.Unknown", ASS.Tag.String, {"value"}, {"string"})
UnknownTag.add, UnknownTag.sub, UnknownTag.mul, UnknownTag.div, UnknownTag.pow, UnknownTag.mod = nil, nil, nil, nil, nil, nil
ASS.Tag.Unknown = UnknownTag

ASS.Draw.Contour        = loadClass("Draw.Contour")
-- Drawing Command Classes
ASS.Draw.Bezier         = loadClass("Draw.Bezier")
ASS.Draw.Close          = loadClass("Draw.Close")
ASS.Draw.Line           = loadClass("Draw.Line")
ASS.Draw.Move           = createASSClass("Draw.Move",   ASS.Draw.CommandBase, {"x", "y"}, {ASS.Number, ASS.Number},
                                         {name="m", ords=2}, {ASS.Point})
ASS.Draw.MoveNc         = createASSClass("Draw.MoveNc", ASS.Draw.CommandBase, {"x", "y"}, {ASS.Number, ASS.Number},
                                         {name="n", ords=2}, {ASS.Draw.Move, ASS.Point})

ASS.Draw.commands = {ASS.Draw.Bezier, ASS.Draw.Close, ASS.Draw.Line, ASS.Draw.Move, ASS.Draw.MoveNc}
table.arrayToSet(ASS.Draw.commands, true)
-- Drawing Command -> Class Mappings
ASS.Draw.commandMapping = {}
for i=1,#ASS.Draw.commands do
    ASS.Draw.commandMapping[ASS.Draw.commands[i].__defProps.name] = ASS.Draw.commands[i]
end

-- Tag Mapping
ASS.tagMap = {
    scale_x =           {overrideName="\\fscx",  type=ASS.Number,        pattern="\\fscx([%d%.]+)",                    format="\\fscx%.3N",
                         sort=6, props={transformable=true}},
    scale_y =           {overrideName="\\fscy",  type=ASS.Number,        pattern="\\fscy([%d%.]+)",                    format="\\fscy%.3N",
                         sort=7, props={transformable=true}},
    align =             {overrideName="\\an",    type=ASS.Tag.Align,     pattern="\\an([1-9])",                        format="\\an%d",
                         sort=1, props={global=true}},
    angle =             {overrideName="\\frz",   type=ASS.Number,        pattern="\\frz?([%-%d%.]+)",                  format="\\frz%.3N",
                         sort=8, props={transformable=true}},
    angle_y =           {overrideName="\\fry",   type=ASS.Number,        pattern="\\fry([%-%d%.]+)",                   format="\\fry%.3N",
                         sort=9, props={transformable=true}, default={0}},
    angle_x =           {overrideName="\\frx",   type=ASS.Number,        pattern="\\frx([%-%d%.]+)",                   format="\\frx%.3N",
                         sort=10, props={transformable=true}, default={0}},
    outline =           {overrideName="\\bord",  type=ASS.Number,        pattern="\\bord([%d%.]+)",                    format="\\bord%.2N",
                         sort=20, props={positive=true, transformable=true}},
    outline_x =         {overrideName="\\xbord", type=ASS.Number,        pattern="\\xbord([%d%.]+)",                   format="\\xbord%.2N",
                         sort=21, props={positive=true, transformable=true}},
    outline_y =         {overrideName="\\ybord", type=ASS.Number,        pattern="\\ybord([%d%.]+)",                   format="\\ybord%.2N",
                         sort=22, props={positive=true, transformable=true}},
    shadow =            {overrideName="\\shad",  type=ASS.Number,        pattern="\\shad([%-%d%.]+)",                  format="\\shad%.2N",
                         sort=23, props={transformable=true}},
    shadow_x =          {overrideName="\\xshad", type=ASS.Number,        pattern="\\xshad([%-%d%.]+)",                 format="\\xshad%.2N",
                         sort=24, props={transformable=true}},
    shadow_y =          {overrideName="\\yshad", type=ASS.Number,        pattern="\\yshad([%-%d%.]+)",                 format="\\yshad%.2N",
                         sort=25, props={transformable=true}},
    reset =             {overrideName="\\r",     type=ASS.Tag.String,    pattern="\\r([^\\}]*)",                       format="\\r%s",
                         props={transformable=true}},
    alpha =             {overrideName="\\alpha", type=ASS.Hex,           pattern="\\alpha&H(%x%x)&",                   format="\\alpha&H%02X&",
                         sort=30, props={transformable=true, masterAlpha=true}, default={0}},
    alpha1 =            {overrideName="\\1a",    type=ASS.Hex,           pattern="\\1a&H(%x%x)&",                      format="\\1a&H%02X&",
                         sort=31, props={transformable=true, childAlpha=true}},
    alpha2 =            {overrideName="\\2a",    type=ASS.Hex,           pattern="\\2a&H(%x%x)&",                      format="\\2a&H%02X&",
                         sort=32, props={transformable=true, childAlpha=true}},
    alpha3 =            {overrideName="\\3a",    type=ASS.Hex,           pattern="\\3a&H(%x%x)&",                      format="\\3a&H%02X&",
                         sort=33, props={transformable=true, childAlpha=true}},
    alpha4 =            {overrideName="\\4a",    type=ASS.Hex,           pattern="\\4a&H(%x%x)&",                      format="\\4a&H%02X&",
                         sort=34, props={transformable=true, childAlpha=true}},
    color =             {overrideName="\\c",     type=ASS.Tag.Color,
                         props={name="color1", transformable=true, pseudo=true}},
    color1 =            {overrideName="\\1c",    type=ASS.Tag.Color,     pattern="\\1?c&H(%x%x)(%x%x)(%x%x)&",         format="\\1c&H%02X%02X%02X&",  friendlyName="\\1c & \\c",
                         sort=26, props={transformable=true}},
    color2 =            {overrideName="\\2c",    type=ASS.Tag.Color,     pattern="\\2c&H(%x%x)(%x%x)(%x%x)&",          format="\\2c&H%02X%02X%02X&",
                         sort=27, props={transformable=true}},
    color3 =            {overrideName="\\3c",    type=ASS.Tag.Color,     pattern="\\3c&H(%x%x)(%x%x)(%x%x)&",          format="\\3c&H%02X%02X%02X&",
                         sort=28, props={transformable=true}},
    color4 =            {overrideName="\\4c",    type=ASS.Tag.Color,     pattern="\\4c&H(%x%x)(%x%x)(%x%x)&",          format="\\4c&H%02X%02X%02X&",
                         sort=29, props={transformable=true}},
    clip_vect =         {overrideName="\\clip",  type=ASS.Tag.ClipVect,  pattern="\\clip%(([mnlbspc] .-)%)",           format="\\clip(%s)",         friendlyName="\\clip (Vector)",
                         sort=41, props={global=true, clip=true}},
    iclip_vect =        {overrideName="\\iclip", type=ASS.Tag.ClipVect,  pattern="\\iclip%(([mnlbspc] .-)%)",          format="\\iclip(%s)",        friendlyName="\\iclip (Vector)",
                         sort=42, props={inverse=true, global=true, clip=true}, default={"m 0 0 l 0 0 0 0 0 0 0 0"}},
    clip_rect =         {overrideName="\\clip",  type=ASS.Tag.ClipRect,  pattern="\\clip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\clip(%.2N,%.2N,%.2N,%.2N)", friendlyName="\\clip (Rectangle)",
                         sort=39, props={transformable=true, global=false, clip=true}},
    iclip_rect =        {overrideName="\\iclip", type=ASS.Tag.ClipRect,  pattern="\\iclip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\iclip(%.2N,%.2N,%.2N,%.2N)", friendlyName="\\iclip (Rectangle)",
                         sort=40, props={inverse=true, global=false, transformable=true, clip=true}, default={0,0,0,0}},
    drawing =           {overrideName="\\p",     type=ASS.Number,        pattern="\\p(%d+)",                           format="\\p%d",
                         sort=44, props={positive=true, integer=true, precision=0}, default={0}},
    blur_edges =        {overrideName="\\be",    type=ASS.Number,        pattern="\\be([%d%.]+)",                      format="\\be%.2N",
                         sort=36, props={positive=true, transformable=true}, default={0}},
    blur =              {overrideName="\\blur",  type=ASS.Number,        pattern="\\blur([%d%.]+)",                    format="\\blur%.2N",
                         sort=35, props={positive=true, transformable=true}, default={0}},
    shear_x =           {overrideName="\\fax",   type=ASS.Number,        pattern="\\fax([%-%d%.]+)",                   format="\\fax%.2N",
                         sort=11, props={transformable=true}, default={0}},
    shear_y =           {overrideName="\\fay",   type=ASS.Number,        pattern="\\fay([%-%d%.]+)",                   format="\\fay%.2N",
                         sort=12, props={transformable=true}, default={0}},
    bold =              {overrideName="\\b",     type=ASS.Tag.Weight,    pattern="\\b(%d+)",                           format="\\b%d",
                         sort=16},
    italic =            {overrideName="\\i",     type=ASS.Tag.Toggle,    pattern="\\i([10])",                          format="\\i%d",
                         sort=17},
    underline =         {overrideName="\\u",     type=ASS.Tag.Toggle,    pattern="\\u([10])",                          format="\\u%d",
                         sort=18},
    strikeout =         {overrideName="\\s",     type=ASS.Tag.Toggle,    pattern="\\s([10])",                          format="\\s%d",
                         sort=19},
    spacing =           {overrideName="\\fsp",   type=ASS.Number,        pattern="\\fsp([%-%d%.]+)",                   format="\\fsp%.2N",
                         sort=15, props={transformable=true}},
    fontsize =          {overrideName="\\fs",    type=ASS.Number,        pattern="\\fs([%d%.]+)",                      format="\\fs%.2N",
                         sort=14, props={positive=true, transformable=true}},
    fontname =          {overrideName="\\fn",    type=ASS.Tag.String,    pattern="\\fn([^\\}]*)",                      format="\\fn%s",
                         sort=13},
    k_fill =            {overrideName="\\k",     type=ASS.Duration,      pattern="\\k([%d]+)",                         format="\\k%d",
                         sort=45, props={scale=10, karaoke=true}, default={0}},
    k_sweep =           {overrideName="\\kf",    type=ASS.Duration,      pattern="\\kf([%d]+)",                        format="\\kf%d",
                         sort=46, props={scale=10, karaoke=true}, default={0}},
    k_sweep_alt =       {overrideName="\\K",     type=ASS.Duration,      pattern="\\K([%d]+)",                         format="\\K%d",
                         sort=47, props={scale=10, karaoke=true}, default={0}},
    k_bord =            {overrideName="\\ko",    type=ASS.Duration,      pattern="\\ko([%d]+)",                        format="\\ko%d",
                         sort=48, props={scale=10, karaoke=true}, default={0}},
    position =          {overrideName="\\pos",   type=ASS.Point,         pattern="\\pos%(([%-%d%.]+),([%-%d%.]+)%)",   format="\\pos(%.3N,%.3N)",
                         sort=2, props={global=true}},
    move_simple =       {overrideName="\\move",  type=ASS.Tag.Move,      pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\move(%.3N,%.3N,%.3N,%.3N)", friendlyName="\\move (Simple)",
                         sort=3, props={simple=true, global=true}},
    move =              {overrideName="\\move",  type=ASS.Tag.Move,      pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),(%d+),(%d+)%)", format="\\move(%.3N,%.3N,%.3N,%.3N,%.3N,%.3N)", friendlyName="\\move (w/ Time)",
                         sort=4, props={global=true}},
    origin =            {overrideName="\\org",   type=ASS.Point,         pattern="\\org%(([%-%d%.]+),([%-%d%.]+)%)",   format="\\org(%.3N,%.3N)",
                         sort=5, props={global=true}},
    wrapstyle =         {overrideName="\\q",     type=ASS.Tag.WrapStyle, pattern="\\q(%d)",                            format="\\q%d",
                         sort=43, props={global=true}, default={0}},
    fade_simple =       {overrideName="\\fad",   type=ASS.Tag.Fade,      pattern="\\fad%((%d+),(%d+)%)",               format="\\fad(%d,%d)",
                         sort=37, props={simple=true, global=true}, default={0,0}},
    fade =              {overrideName="\\fade",  type=ASS.Tag.Fade,      pattern="\\fade%((%d+),(%d+),(%d+),([%-%d]+),([%-%d]+),([%-%d]+),([%-%d]+)%)", format="\\fade(%d,%d,%d,%d,%d,%d,%d)",
                         sort=38, props={global=true}, default={255,0,255,0,0,0,0}},
    transform =         {overrideName="\\t",     type=ASS.Tag.Transform,
                         props={pseudo=true}},
    transform_simple =  {overrideName="\\t",     type=ASS.Tag.Transform, pattern="\\t%(([^,]+)%)",                     format="\\t(%s)"},
    transform_accel =   {overrideName="\\t",     type=ASS.Tag.Transform, pattern="\\t%(([%d%.]+),([^,]+)%)",           format="\\t(%.2N,%s)"},
    transform_time =    {overrideName="\\t",     type=ASS.Tag.Transform, pattern="\\t%(([%-%d]+),([%-%d]+),([^,]+)%)", format="\\t(%.2N,%.2N,%s)"},
    transform_complex = {overrideName="\\t",     type=ASS.Tag.Transform, pattern="\\t%(([%-%d]+),([%-%d]+),([%d%.]+),([^,]+)%)", format="\\t(%.2N,%.2N,%.2N,%s)"},
    unknown =           {                        type=ASS.Tag.Unknown,                                                 format="%s", friendlyName="Unknown Tag",
                         sort=98},
    junk =              {                        type=ASS.Tag.Unknown,                                                 format="%s", friendlyName="Junk",
                         sort=99}
}

ASS.tagNames = {
    all        = table.keys(ASS.tagMap),
    noPos      = table.keys(ASS.tagMap, "position"),
    clips      = ASS:getTagsNamesFromProps{clip=true},
    karaoke    = ASS:getTagsNamesFromProps{karaoke=true},
    childAlpha = ASS:getTagsNamesFromProps{childAlpha=true}
}

ASS.toFriendlyName, ASS.toTagName, ASS.tagSortOrder = {}, {}, {}

for name,tag in pairs(ASS.tagMap) do
    -- insert tag name into props
    tag.props = tag.props or {}
    tag.props.name = tag.props.name or name
    -- generate properties for treating rectangular clips as global tags
    tag.props.globalOrRectClip = tag.props.global or tag.type==ASS.Tag.ClipRect
    -- fill in missing friendly names
    tag.friendlyName = tag.friendlyName or tag.overrideName
    -- populate friendly name <-> tag name conversion tables
    if tag.friendlyName then
        ASS.toFriendlyName[name], ASS.toTagName[tag.friendlyName] = tag.friendlyName, name
    end
    -- fill tag names table
    local tagType = ASS.tagNames[tag.type]
    if not tagType then
        ASS.tagNames[tag.type] = {name, n=1}
    else
        tagType[tagType.n+1], tagType.n = name, tagType.n+1
    end
    -- fill override tag name -> internal tag name mapping tables
    if tag.overrideName then
        local ovrToName = ASS.tagNames[tag.overrideName]
        if ovrToName then
            ovrToName[#ovrToName+1] = name
        else ASS.tagNames[tag.overrideName] = {name} end
    end
    -- fill sort order table
    if tag.sort then
        ASS.tagSortOrder[tag.sort] = name
    end
end

ASS.tagSortOrder = table.reduce(ASS.tagSortOrder)

-- make name tables also work as sets
for _,names in pairs(ASS.tagNames) do
    if not names.n then names.n = #names end
    table.arrayToSet(names, true)
end

ASS.defaults = {
    line = {actor="", class="dialogue", comment=false, effect="", start_time=0, end_time=5000, layer=0,
            margin_l=0, margin_r=0, margin_t=0, section="[Events]", style="Default", text="", extra={}},
    drawingTestTags = ASS.Section.Tag{ASS:createTag("position",0,0), ASS:createTag("align",7),
                       ASS:createTag("outline", 0), ASS:createTag("scale_x", 100), ASS:createTag("scale_y", 100),
                       ASS:createTag("alpha", 0), ASS:createTag("angle", 0), ASS:createTag("shadow", 0)}
}

ASS.version = version

local ASSFInst = ASS()
ASSFInstMeta.__index = ASSFInst

return version:register(ASSFInst)