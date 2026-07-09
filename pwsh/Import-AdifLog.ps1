#Requires -Version 7.0
<#
.SYNOPSIS
    Parses ADIF (.adi) amateur radio log files into strongly-typed pipeline objects.

.DESCRIPTION
    Streams QSO records from one or more ADIF files as PSCustomObjects with typed
    properties. Dates, times, numbers, booleans, and latitude/longitude values
    are converted to their native .NET types. QSO_DATE + TIME_ON are combined
    into a UTC QsoDateTime, and QSO_DATE_OFF + TIME_OFF into QsoDateTimeOff.

    Field names are normalized from ADIF's UPPER_SNAKE_CASE into PascalCase
    (e.g., QSO_DATE -> QsoDate, MY_SIG_INFO -> MySigInfo).

.EXAMPLE
    Import-AdifLog .\log.adi | Where-Object Band -eq '20m' | Sort-Object QsoDateTime

.EXAMPLE
    Get-ChildItem *.adi | Import-AdifLog | Group-Object Mode | Sort-Object Count -Descending

.EXAMPLE
    Import-AdifLog .\log.adi |
        Where-Object { $_.QsoDateTime -gt (Get-Date).AddDays(-30) } |
        Measure-Object -Property TxPwr -Average
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
    [Alias('FullName', 'PSPath')]
    [string[]]$Path
)

begin {
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    $numericFields = [System.Collections.Generic.HashSet[string]]@(
        'FREQ', 'FREQ_RX', 'TX_PWR', 'RX_PWR', 'DISTANCE', 'ANT_AZ', 'ANT_EL',
        'A_INDEX', 'K_INDEX', 'SFI', 'MAX_BURSTS', 'NR_BURSTS', 'NR_PINGS',
        'ALTITUDE', 'MY_ALTITUDE', 'AGE', 'STX', 'SRX'
    )

    $integerFields = [System.Collections.Generic.HashSet[string]]@(
        'DXCC', 'MY_DXCC', 'CQZ', 'MY_CQ_ZONE', 'ITUZ', 'MY_ITU_ZONE',
        'IOTA_ISLAND_ID', 'TEN_TEN', 'FISTS', 'FISTS_CC'
    )

    $booleanFields = [System.Collections.Generic.HashSet[string]]@(
        'SWL', 'FORCE_INIT', 'SILENT_KEY', 'QRP', 'QSO_RANDOM'
    )

    $dateFields = [System.Collections.Generic.HashSet[string]]@(
        'QSO_DATE', 'QSO_DATE_OFF',
        'QSLRDATE', 'QSLSDATE',
        'LOTW_QSLRDATE', 'LOTW_QSLSDATE',
        'EQSL_QSLRDATE', 'EQSL_QSLSDATE',
        'HRDLOG_QSO_UPLOAD_DATE', 'CLUBLOG_QSO_UPLOAD_DATE', 'QRZCOM_QSO_UPLOAD_DATE'
    )

    $latLongFields = [System.Collections.Generic.HashSet[string]]@(
        'LAT', 'LON', 'MY_LAT', 'MY_LON'
    )

    function ConvertTo-PascalCase {
        param([string]$Name)

        $parts = $Name.Split('_', [System.StringSplitOptions]::RemoveEmptyEntries)
        ($parts | ForEach-Object {
            $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
        }) -join ''
    }

    function ConvertTo-AdifDateTime {
        param([string]$Date, [string]$Time)

        if (-not $Date) {
            return $null
        }

        $t = if ($Time) { $Time.PadRight(6, '0').Substring(0, 6) } else { '000000' }
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
                  [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $parsed = [datetime]::MinValue

        if ([datetime]::TryParseExact($Date + $t, 'yyyyMMddHHmmss', $invariant, $styles, [ref]$parsed)) {
            return $parsed
        }

        $null
    }

    function ConvertTo-AdifLatLong {
        param([string]$Value)

        if ($Value -match '^(?<h>[NSEW])(?<d>\d{3})\s(?<m>\d{2}\.\d+)$') {
            $sign = if ($Matches.h -in 'S', 'W') { -1.0 } else { 1.0 }
            return $sign * ([int]$Matches.d + [double]::Parse($Matches.m, $invariant) / 60.0)
        }

        $null
    }

    function Convert-AdifValue {
        param([string]$Name, [string]$Type, [string]$Value)

        if ([string]::IsNullOrEmpty($Value)) {
            return $Value
        }

        $t = if ($Type) { $Type.ToUpperInvariant() } else { '' }
        $intVal = 0
        $dblVal = 0.0
        $dtVal = [datetime]::MinValue

        switch ($t) {
            'B' { return $Value -match '^[YyTt1]' }
            'N' {
                if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$dblVal)) {
                    return $dblVal
                }
            }
            'D' {
                if ([datetime]::TryParseExact($Value, 'yyyyMMdd', $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$dtVal)) {
                    return $dtVal
                }
            }
            'L' {
                $ll = ConvertTo-AdifLatLong $Value
                if ($null -ne $ll) {
                    return $ll
                }
            }
        }

        if ($booleanFields.Contains($Name)) {
            return $Value -match '^[YyTt1]'
        }

        if ($integerFields.Contains($Name)) {
            if ([int]::TryParse($Value, [System.Globalization.NumberStyles]::Integer, $invariant, [ref]$intVal)) {
                return $intVal
            }
        }

        if ($numericFields.Contains($Name)) {
            if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$dblVal)) {
                return $dblVal
            }
        }

        if ($dateFields.Contains($Name)) {
            if ([datetime]::TryParseExact($Value, 'yyyyMMdd', $invariant, [System.Globalization.DateTimeStyles]::None, [ref]$dtVal)) {
                return $dtVal
            }
        }

        if ($latLongFields.Contains($Name)) {
            $ll = ConvertTo-AdifLatLong $Value
            if ($null -ne $ll) {
                return $ll
            }
        }

        $Value
    }

    function Read-AdifFile {
        param([string]$FilePath)

        $text = [System.IO.File]::ReadAllText($FilePath)
        $eoh = [regex]::Match($text, '<EOH>', 'IgnoreCase')
        $body = if ($eoh.Success) { $text.Substring($eoh.Index + $eoh.Length) } else { $text }

        $fields = [ordered]@{}
        $rawDate = $null
        $rawTime = $null
        $rawDateOff = $null
        $rawTimeOff = $null
        $i = 0

        while ($i -lt $body.Length) {
            $lt = $body.IndexOf('<', $i)

            if ($lt -lt 0) {
                break
            }

            $gt = $body.IndexOf('>', $lt + 1)

            if ($gt -lt 0) {
                break
            }

            $tag = $body.Substring($lt + 1, $gt - $lt - 1)
            $parts = $tag.Split(':')
            $name = $parts[0].ToUpperInvariant()

            if ($name -eq 'EOR') {
                if ($fields.Count -gt 0) {
                    $fields['QsoDateTime'] = ConvertTo-AdifDateTime $rawDate $rawTime
                    $fields['QsoDateTimeOff'] = ConvertTo-AdifDateTime ($rawDateOff ?? $rawDate) ($rawTimeOff ?? $rawTime)
                    $fields['SourceFile'] = $FilePath
                    [pscustomobject]$fields
                }

                $fields = [ordered]@{}
                $rawDate = $null
                $rawTime = $null
                $rawDateOff = $null
                $rawTimeOff = $null
                $i = $gt + 1
                continue
            }

            $len = 0

            if ($parts.Count -lt 2 -or -not [int]::TryParse($parts[1], [ref]$len)) {
                $i = $gt + 1
                continue
            }

            $type = if ($parts.Count -ge 3) { $parts[2] } else { $null }
            $valStart = $gt + 1

            if ($valStart + $len -gt $body.Length) {
                break
            }

            $value = $body.Substring($valStart, $len)

            switch ($name) {
                'QSO_DATE'     { $rawDate    = $value }
                'TIME_ON'      { $rawTime    = $value }
                'QSO_DATE_OFF' { $rawDateOff = $value }
                'TIME_OFF'     { $rawTimeOff = $value }
            }

            $fields[(ConvertTo-PascalCase $name)] = Convert-AdifValue $name $type $value
            $i = $valStart + $len
        }
    }
}

process {
    foreach ($p in $Path) {
        $resolved = Resolve-Path -LiteralPath $p -ErrorAction Stop

        foreach ($r in $resolved) {
            Read-AdifFile -FilePath $r.ProviderPath
        }
    }
}
