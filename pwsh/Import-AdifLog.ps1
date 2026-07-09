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

# We use an embedded C# program for performance reasons. The original PowerShell-only version was taking 16 seconds to process
# a moderately sized log (~1500 QSOs), whereas using C# gets the time down to under one second.
begin {
    if (-not ('AdifTools.AdifLogParser' -as [type])) {
        Add-Type -TypeDefinition @'
namespace AdifTools
{
    using System;
    using System.Collections;
    using System.Collections.Generic;
    using System.Collections.Specialized;
    using System.Globalization;
    using System.IO;
    using System.Management.Automation;
    using System.Text;

    public static class AdifLogParser
    {
        private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
        private static readonly DateTimeStyles AdifDateTimeStyles = DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal;

        private static readonly HashSet<string> NumericFields = new HashSet<string>(StringComparer.Ordinal)
        {
            "FREQ", "FREQ_RX", "TX_PWR", "RX_PWR", "DISTANCE", "ANT_AZ", "ANT_EL",
            "A_INDEX", "K_INDEX", "SFI", "MAX_BURSTS", "NR_BURSTS", "NR_PINGS",
            "ALTITUDE", "MY_ALTITUDE", "AGE", "STX", "SRX"
        };

        private static readonly HashSet<string> IntegerFields = new HashSet<string>(StringComparer.Ordinal)
        {
            "DXCC", "MY_DXCC", "CQZ", "MY_CQ_ZONE", "ITUZ", "MY_ITU_ZONE",
            "IOTA_ISLAND_ID", "TEN_TEN", "FISTS", "FISTS_CC"
        };

        private static readonly HashSet<string> BooleanFields = new HashSet<string>(StringComparer.Ordinal)
        {
            "SWL", "FORCE_INIT", "SILENT_KEY", "QRP", "QSO_RANDOM"
        };

        private static readonly HashSet<string> DateFields = new HashSet<string>(StringComparer.Ordinal)
        {
            "QSO_DATE", "QSO_DATE_OFF",
            "QSLRDATE", "QSLSDATE",
            "LOTW_QSLRDATE", "LOTW_QSLSDATE",
            "EQSL_QSLRDATE", "EQSL_QSLSDATE",
            "HRDLOG_QSO_UPLOAD_DATE", "CLUBLOG_QSO_UPLOAD_DATE", "QRZCOM_QSO_UPLOAD_DATE"
        };

        private static readonly HashSet<string> LatLongFields = new HashSet<string>(StringComparer.Ordinal)
        {
            "LAT", "LON", "MY_LAT", "MY_LON"
        };

        private static readonly Dictionary<string, string> PascalCaseCache = new Dictionary<string, string>(StringComparer.Ordinal);

        public static IEnumerable<PSObject> ReadFile(string filePath)
        {
            string text = File.ReadAllText(filePath);
            int eoh = text.IndexOf("<EOH>", StringComparison.OrdinalIgnoreCase);
            int bodyStart = eoh >= 0 ? eoh + 5 : 0;
            var fields = new OrderedDictionary();
            string rawDate = null;
            string rawTime = null;
            string rawDateOff = null;
            string rawTimeOff = null;
            int i = bodyStart;

            while (i < text.Length)
            {
                int lt = text.IndexOf('<', i);

                if (lt < 0)
                {
                    yield break;
                }

                int gt = text.IndexOf('>', lt + 1);

                if (gt < 0)
                {
                    yield break;
                }

                int firstColon = IndexOfBefore(text, ':', lt + 1, gt);

                if (firstColon < 0)
                {
                    string name = text.Substring(lt + 1, gt - lt - 1).ToUpperInvariant();

                    if (name == "EOR")
                    {
                        if (fields.Count > 0)
                        {
                            fields["QsoDateTime"] = ConvertToAdifDateTime(rawDate, rawTime);
                            fields["QsoDateTimeOff"] = ConvertToAdifDateTime(rawDateOff ?? rawDate, rawTimeOff ?? rawTime);
                            fields["SourceFile"] = filePath;

                            yield return ToPSObject(fields);
                        }

                        fields = new OrderedDictionary();
                        rawDate = null;
                        rawTime = null;
                        rawDateOff = null;
                        rawTimeOff = null;
                    }

                    i = gt + 1;
                    continue;
                }

                string fieldName = text.Substring(lt + 1, firstColon - lt - 1).ToUpperInvariant();
                int secondColon = IndexOfBefore(text, ':', firstColon + 1, gt);
                bool hasType = secondColon >= 0;
                int lengthEnd = hasType ? secondColon : gt;

                if (!int.TryParse(text.Substring(firstColon + 1, lengthEnd - firstColon - 1), out int len))
                {
                    i = gt + 1;
                    continue;
                }

                string type = hasType ? text.Substring(secondColon + 1, gt - secondColon - 1) : null;
                int valueStart = gt + 1;

                if (valueStart + len > text.Length)
                {
                    yield break;
                }

                string value = text.Substring(valueStart, len);

                switch (fieldName)
                {
                    case "QSO_DATE":
                        rawDate = value;
                        break;
                    case "TIME_ON":
                        rawTime = value;
                        break;
                    case "QSO_DATE_OFF":
                        rawDateOff = value;
                        break;
                    case "TIME_OFF":
                        rawTimeOff = value;
                        break;
                }

                fields[ConvertToPascalCase(fieldName)] = ConvertAdifValue(fieldName, type, value);
                i = valueStart + len;
            }
        }

        private static int IndexOfBefore(string value, char target, int startIndex, int endIndex)
        {
            for (int i = startIndex; i < endIndex; i++)
            {
                if (value[i] == target)
                {
                    return i;
                }
            }

            return -1;
        }

        private static PSObject ToPSObject(OrderedDictionary fields)
        {
            var obj = new PSObject();

            foreach (DictionaryEntry entry in fields)
            {
                obj.Properties.Add(new PSNoteProperty((string)entry.Key, entry.Value));
            }

            return obj;
        }

        private static string ConvertToPascalCase(string name)
        {
            if (PascalCaseCache.TryGetValue(name, out string cached))
            {
                return cached;
            }

            var builder = new StringBuilder(name.Length);
            int partStart = 0;

            for (int i = 0; i <= name.Length; i++)
            {
                if (i != name.Length && name[i] != '_')
                {
                    continue;
                }

                int partLength = i - partStart;

                if (partLength > 0)
                {
                    builder.Append(char.ToUpperInvariant(name[partStart]));

                    for (int j = partStart + 1; j < i; j++)
                    {
                        builder.Append(char.ToLowerInvariant(name[j]));
                    }
                }

                partStart = i + 1;
            }

            string result = builder.ToString();
            PascalCaseCache[name] = result;

            return result;
        }

        private static DateTime? ConvertToAdifDateTime(string date, string time)
        {
            if (string.IsNullOrEmpty(date))
            {
                return null;
            }

            string t = string.IsNullOrEmpty(time)
                ? "000000"
                : time.Length >= 6
                    ? time.Substring(0, 6)
                    : time.PadRight(6, '0');

            if (DateTime.TryParseExact(date + t, "yyyyMMddHHmmss", Invariant, AdifDateTimeStyles, out DateTime parsed))
            {
                return parsed;
            }

            return null;
        }

        private static object ConvertAdifValue(string name, string type, string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return value;
            }

            char typeCode = string.IsNullOrEmpty(type) ? '\0' : char.ToUpperInvariant(type[0]);

            if (typeCode == 'B')
            {
                return IsAdifTrue(value);
            }

            if (typeCode == 'N' && double.TryParse(value, NumberStyles.Float, Invariant, out double doubleValue))
            {
                return doubleValue;
            }

            if (typeCode == 'D' && DateTime.TryParseExact(value, "yyyyMMdd", Invariant, DateTimeStyles.None, out DateTime dateValue))
            {
                return dateValue;
            }

            if (typeCode == 'L' && TryParseLatLong(value, out double latLongValue))
            {
                return latLongValue;
            }

            if (BooleanFields.Contains(name))
            {
                return IsAdifTrue(value);
            }

            if (IntegerFields.Contains(name) && int.TryParse(value, NumberStyles.Integer, Invariant, out int intValue))
            {
                return intValue;
            }

            if (NumericFields.Contains(name) && double.TryParse(value, NumberStyles.Float, Invariant, out doubleValue))
            {
                return doubleValue;
            }

            if (DateFields.Contains(name) && DateTime.TryParseExact(value, "yyyyMMdd", Invariant, DateTimeStyles.None, out dateValue))
            {
                return dateValue;
            }

            if (LatLongFields.Contains(name) && TryParseLatLong(value, out latLongValue))
            {
                return latLongValue;
            }

            return value;
        }

        private static bool IsAdifTrue(string value)
        {
            char c = value[0];

            return c == 'Y' || c == 'y' || c == 'T' || c == 't' || c == '1';
        }

        private static bool TryParseLatLong(string value, out double result)
        {
            result = 0.0;

            if (value.Length < 9)
            {
                return false;
            }

            char hemisphere = value[0];

            if (hemisphere != 'N' && hemisphere != 'S' && hemisphere != 'E' && hemisphere != 'W')
            {
                return false;
            }

            if (!char.IsDigit(value[1]) || !char.IsDigit(value[2]) || !char.IsDigit(value[3]) ||
                !char.IsWhiteSpace(value[4]) ||
                !char.IsDigit(value[5]) || !char.IsDigit(value[6]) ||
                value[7] != '.')
            {
                return false;
            }

            for (int i = 8; i < value.Length; i++)
            {
                if (!char.IsDigit(value[i]))
                {
                    return false;
                }
            }

            if (!int.TryParse(value.Substring(1, 3), NumberStyles.None, Invariant, out int degrees) ||
                !double.TryParse(value.Substring(5), NumberStyles.Float, Invariant, out double minutes))
            {
                return false;
            }

            double sign = hemisphere == 'S' || hemisphere == 'W' ? -1.0 : 1.0;
            result = sign * (degrees + minutes / 60.0);

            return true;
        }
    }
}
'@
    }
}

process {
    foreach ($p in $Path) {
        $resolved = Resolve-Path -LiteralPath $p -ErrorAction Stop

        foreach ($r in $resolved) {
            foreach ($qso in [AdifTools.AdifLogParser]::ReadFile($r.ProviderPath)) {
                $qso
            }
        }
    }
}
