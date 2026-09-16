@{
    # Rules excluded with justification for these two operator tools. Everything else
    # in the default PSScriptAnalyzer ruleset must pass clean.
    ExcludeRules = @(
        # These are interactive, colored console tools. Write-Host is the correct choice
        # for user-facing status output (it also feeds the WinForms live log); switching to
        # Write-Output/Write-Information would break the color UX and pollute the pipeline.
        'PSAvoidUsingWriteHost',

        # Internal helpers named with Set-/Update- verbs (Set-EmptyArp, Update-GuiStatus).
        # They are not public cmdlets; the scripts already gate destructive work behind
        # -Execute/-Force and explicit confirmation, so -WhatIf/-Confirm plumbing is redundant.
        'PSUseShouldProcessForStateChangingFunctions',

        # Get-EvsServices intentionally returns a collection of services; the plural reads
        # correctly at every call site.
        'PSUseSingularNouns'
    )
}
