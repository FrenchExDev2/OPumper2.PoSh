# Below this many deliveries a command has no advice: a single run proves nothing.
$script:OP2AdviceMinimum = 3

# Each rule reads one command group and returns its advice, or nothing. A new rule appends one entry.
$script:OP2AdviceRules = [ordered]@{
    NegativeSavings = { param($group)
        if ($group.TokenCompared -ge $script:OP2AdviceMinimum -and $group.SavedTokens -lt 0) {
            "costs $(-$group.SavedTokens) more tokens than its native output over $($group.TokenCompared) deliveries: deliver a smaller projection, or lower MaxItems and ExcerptLines."
        } }
    FrequentRerun = { param($group)
        if ($group.Compared -ge $script:OP2AdviceMinimum -and $group.RerunRate -ge 0.2) {
            "is run again within the rerun window after $(Format-OP2GainRate $group.RerunRate) of its deliveries: its delivery probably misses information."
        } }
    FrequentRecall = { param($group)
        if ($group.Stored -ge $script:OP2AdviceMinimum -and $group.RecallRate -ge 0.2) {
            "is read back from the recall store after $(Format-OP2GainRate $group.RecallRate) of its deliveries: deliver what is read back."
        } }
    LossyDelivery = { param($group)
        if ($group.Compared -ge $script:OP2AdviceMinimum -and $group.LossyRate -ge 0.2) {
            "is truncated in $(Format-OP2GainRate $group.LossyRate) of its deliveries: raise MaxOutputBytes or narrow the request."
        } }
    ExcerptHeavy = { param($group)
        if ($group.Compared -ge $script:OP2AdviceMinimum -and $null -ne $group.Layers -and $group.Layers.Excerpt -gt $group.Layers.Data) {
            'delivers more failure excerpt than Data: a contract or route that parses its failures would replace raw lines.'
        } }
    CheaperFormat = { param($group)
        if ($null -ne $group.Alternate -and $group.Alternate.Compared -ge $script:OP2AdviceMinimum -and $group.Alternate.Rate -ge 0.1) {
            "would be $(Format-OP2GainRate $group.Alternate.Rate) smaller in $($group.Alternate.Format)."
        } }
}

function Get-OP2GainAdvice {
    param([object[]]$Groups)
    foreach ($group in $Groups) {
        foreach ($rule in $script:OP2AdviceRules.GetEnumerator()) {
            $advice = & $rule.Value $group
            if ($advice) { [pscustomobject][ordered]@{ Command = $group.Key; Rule = $rule.Key; Advice = "$($group.Key) $advice" } }
        }
    }
}
