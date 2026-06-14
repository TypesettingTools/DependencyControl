---Interface to a local git repository for running git commands.
---@class GitRepository
class GitRepository
    ---Creates an interface to the git repository rooted at `dir`.
    ---@param dir string Absolute path to the repository root.
    new: (@dir) =>

    ---Runs a git command and returns trimmed stdout+stderr, or nil on failure or empty output.
    ---@param args string Command and flags passed verbatim after `git -C <dir>`.
    ---@return string? output
    run: (args) =>
        h = io.popen ('git -C "%s" %s 2>&1')\format @dir, args
        return nil unless h
        out = (h\read("*a") or "")\gsub "%s+$", ""
        h\close! and out != "" and out or nil

    
    getBranch: (ref = "HEAD") => @run "rev-parse --abbrev-ref #{ref}"
    getCommitHash: (ref = "HEAD") => @run "rev-parse --short=7 #{ref}"
    isAtTag: (ref = "HEAD") => not not @run "describe --exact-match --tags #{ref}"

    ---Returns a git describe-style version suffix for the current HEAD.
    ---Returns "" when HEAD is exactly on a tag, "-<branch>-g<hash>" otherwise.
    ---@return string suffix
    getVersionSuffix: =>
        return "" if @isAtTag!
        branch = @getBranch! or "unknown"
        hash   = @getCommitHash! or "0000000"
        "-#{branch}-g#{hash}"
