local _, addon = ...

-- Fills in a Guild Mail's subject and body for one recipient, with the same
-- placeholders as Guild Greet ({name}, {main}, {mainFirst}, {mainLast},
-- {character}, {characterFirst}, {characterLast}, in any case), and checks
-- the filled-in mail against the game's limits. {character} is the
-- character the mail is addressed to.
--
-- Pure: it reads a FellowshipStore partition and a NameNormalizer, and never
-- touches the game.
local GuildMailComposer = {
    -- The game's limits on a mail's subject and body, in letters.
    SUBJECT_LETTERS = 64,
    BODY_LETTERS = 500,
    -- Every placeholder and what a mail fills it with. Case doesn't matter.
    PLACEHOLDERS = {
        { "{name}", "their alias, else their main's name" },
        { "{main}", "their main's name, even when they have an alias" },
        { "{mainFirst}", "the first part of their main's name" },
        { "{mainLast}", "the last part of their main's name" },
        { "{character}", "the character the mail is sent to" },
        { "{characterFirst}", "the first part of that character's name" },
        { "{characterLast}", "the last part of that character's name" },
    },
}
addon.GuildMailComposer = GuildMailComposer

-- The number of letters in UTF-8 `text`, as the game counts them.
function GuildMailComposer.Letters(text)
    local _, continuation = string.gsub(text, "[\128-\191]", "")
    return string.len(text) - continuation
end

-- `subject` and `body` filled in for `recipient` ({ key, name }, `name`
-- spelled as the roster does) in `partition` with `normalizer` (either may
-- be nil):
--   { subject, body, warning }
-- `warning` says what's over the game's limit, or is nil when the mail fits.
function GuildMailComposer.Compose(subject, body, recipient, partition, normalizer)
    local names = addon.GuildGreet.NamesFor(partition, normalizer, recipient.key, recipient.name)
    local mail = {
        subject = addon.GreetingLibrary.Fill(subject or "", names),
        body = addon.GreetingLibrary.Fill(body or "", names),
    }
    local subjectLetters = GuildMailComposer.Letters(mail.subject)
    local bodyLetters = GuildMailComposer.Letters(mail.body)
    local problems = {}
    if subjectLetters > GuildMailComposer.SUBJECT_LETTERS then
        table.insert(problems, "subject too long (" .. subjectLetters .. "/" .. GuildMailComposer.SUBJECT_LETTERS .. ")")
    end
    if bodyLetters > GuildMailComposer.BODY_LETTERS then
        table.insert(problems, "message too long (" .. bodyLetters .. "/" .. GuildMailComposer.BODY_LETTERS .. ")")
    end
    if #problems > 0 then
        mail.warning = table.concat(problems, ", ")
    end
    return mail
end
