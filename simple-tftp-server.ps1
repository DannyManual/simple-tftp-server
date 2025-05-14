# Simple TFTP Server in PowerShell
# Einfache Implementierung eines TFTP-Servers in PowerShell
# Dieser TFTP-Server unterstützt nur WRQ (Write Request) und DATA-Pakete.
# Er kann keine RRQ (Read Request) verarbeiten.
# Der Server speichert empfangene Dateien im aktuellen Verzeichnis.
#
# Skript erzeugt mithilfe von ChatGPT
# Datum: 2025-14-05
# Version: 1.0
#
# Datenschutz-Hinweis:
# Dieses Skript verarbeitet keine personenbezogenen Daten und speichert keine Informationen über die Benutzer.
# Es werden keine Daten an Dritte weitergegeben oder gespeichert.
# Die Verwendung des Skripts erfolgt auf eigenes Risiko.
# Der Autor übernimmt keine Haftung für Schäden, die durch die Verwendung des Skripts entstehen.
#
# Lizenz-Hinweis: kann beliebig kopiert und verändert werden

# Prepare Assembly
Add-Type -AssemblyName System.Net
Add-Type -AssemblyName System.IO

# Sicherstellen, dass Umlaute korrekt verarbeitet werden
[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Opcodes für TFTP-Protokoll
[byte]$TFTP_OPCODE_RRQ = 0x01
[byte]$TFTP_OPCODE_WRQ = 0x02
[byte]$TFTP_OPCODE_DATA = 0x03
[byte]$TFTP_OPCODE_ACK = 0x04
[byte]$TFTP_OPCODE_ERROR = 0x05

# Port für den TFTP-Server
$Port = 6969

# Scriptverzeichnis als Arbeitsverzeichnis setzen
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkingDirectory = $ScriptDirectory

# Objekte für den TFTP-Server und Endpunkt erstellen
$UdpClient = New-Object System.Net.Sockets.UdpClient $Port
$Endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
$UdpClient.Client.ReceiveTimeout = 5000 # 5 Sekunden Timeout

Write-Host "TFTP-Server läuft auf Port $Port und unterstützt nur Schreibanforderungen (WRQ), keine Leseanforderungen (RRQ). Warte 5 Sekunden auf Anfragen..."

# Variable zur Steuerung der Schleife
$keepRunning = $true


try {
  # Variablen für den Empfang vorbereiten
  $blockSize = 0
  $currentBlockNumber = 0
  $lastBlockNumber = -1
  $fileName = ""
  $fileSize = 0
  $filePath = ""

  # Dateiempfangsmodus initialisieren
  $fileReceivingMode = $false

  while ($keepRunning) {
    # Empfange Daten vom Client (Blockieren)
    $ReceiveBytes = $UdpClient.Receive([ref]$Endpoint)

    # Konvertiere die empfangenen Bytes in ASCII-Text
    $AsciiText = [System.Text.Encoding]::ASCII.GetString($ReceiveBytes)

    # Die ersten 2.Byte enthalten den Opcode
    $OpcodeBytes = $ReceiveBytes[0..1]
    [array]::Reverse($OpcodeBytes) # kommt als Big Endian daher reversieren
    $Opcode = [BitConverter]::ToUInt16($OpcodeBytes, 0)
    
    # Switch basierend auf Opcode
    switch ($Opcode) {
      $TFTP_OPCODE_RRQ {
        # RRQ
        Write-Host "RRQ-Anforderung empfangen von $($Endpoint.Address):$($Endpoint.Port)"
        Write-Host "Dieser TFTP-Server unterstützt keine Leseanforderungen (RRQ)."
        #
        continue
      }
      
      $TFTP_OPCODE_WRQ {
        # WRQ

        # Prüfen, ob bereits eine WRQ-Anforderung aktiv ist
        if ($fileReceivingMode) {
          Write-Host "Bereits eine WRQ-Anforderung aktiv. "
          
          # Zutaten für ERROR-Paket
          $opcode = $TFTP_OPCODE_ERROR # ERROR Opcode 
          $errorCode = 4 # Fehlercode 4: Illegal TFTP Operation
          
          # Byte Array von 2 Bytes aus Opcode mit Big Endian vorbereiten	
          $arrayOpcode = [System.BitConverter]::GetBytes($opcode)
          [array]::Reverse($arrayOpcode)

          # Byte Array von 2 Bytes aus Fehlercode mit Big Endian vorbereiten
          $arrayErrorCode = [System.BitConverter]::GetBytes($errorCode)
          [array]::Reverse($arrayErrorCode)

          # Fehlernachricht als Byte Array
          $errorMessage = "Bereits eine WRQ-Anforderung aktiv." # ASCII
          $arrayErrorMessage = [System.Text.Encoding]::ASCII.GetBytes($errorMessage)
          
          # Byte Array für ERROR-Paket erstellen
          $array = $arrayOpcode + $arrayErrorCode + $arrayErrorMessage + [byte]0
          
          # Fehlerantwort senden
          $UdpClient.Send($array, $array.Length, $Endpoint)
          Write-Host "Fehlerantwort gesendet an $($Endpoint.Address):$($Endpoint.Port)"
          
          continue
        }

        Write-Host "WRQ-Anforderung empfangen von $($Endpoint.Address):$($Endpoint.Port)"
        Write-Host "Datei wird empfangen..."

        # Header-Daten auslesen
        $headerParts = $AsciiText.Substring(2).Split([char]0) # nach dem 2.Byte anhand null-Byte splitten
        
        # Dateipfad vorbereiten
        $fileName = $headerParts[0]
        $filePath = Join-Path -Path $WorkingDirectory -ChildPath $fileName

        # Modus auslesen (z.B. octet)
        $mode = $headerParts[1] 
        
        $options = @{}

        # Optionen auslesen (falls vorhanden) und in ein Dictionary speichern
        for ($i = 2; $i -lt $headerParts.Length - 1; $i += 2) {
          $key = $headerParts[$i]
          $value = $headerParts[$i + 1]
          $options[$key.ToLower()] = $value
        }
        
        # Modus validieren
        if ($mode -ne "octet") {
          Write-Host "Ungültiger Modus. Nur 'octet' wird unterstützt. Übertragung abgebrochen."
          continue
        }

        # Dateigröße validieren
        if ($options.ContainsKey("tsize") -and [int]$options["tsize"] -gt 0) {
          $fileSize = [int]$options["tsize"]
        }
        else {
          Write-Host "Ungültige oder fehlende tsize-Option. Übertragung abgebrochen."
          continue
        }
        
        # Blockgröße validieren
        if ($options.ContainsKey("blksize") -and [int]$options["blksize"] -ge 8 -and [int]$options["blksize"] -le 65464) {
          $blockSize = [int]$options["blksize"]
        }
        else {
          Write-Host "Ungültige oder fehlende blksize-Option. Übertragung abgebrochen."
          continue
        }

        # Datei erstellen
        $filePath = Join-Path -Path $WorkingDirectory -ChildPath $fileName
        $fileStream = [System.IO.File]::Create($filePath)
        Write-Host "Datei '$fileName' wird im Verzeichnis '$WorkingDirectory' erstellt."

        # Datei-Stream schließen (wird später für Datenübertragung benötigt)
        $fileStream.Close()

        # Zutaten für ACK-Paket
        $opcode = $TFTP_OPCODE_ACK # ACK Opcode
        $currentBlockNumber = 0 # Bei ACK für WRQ ist der Block 0
        
        # Byte Array von 2 Bytes aus Opcode mit Big Endian vorbereiten
        $arrayOpcode = [System.BitConverter]::GetBytes($opcode)
        [array]::Reverse($arrayOpcode)
        
        # Byte Array von 2 Bytes aus Blocknummer mit Big Endian vorbereiten
        $arrayBlockNumber = [System.BitConverter]::GetBytes($currentBlockNumber)
        [array]::Reverse($arrayBlockNumber)

        # Byte Arrays verketten
        $bytes = $arrayOpcode + $arrayBlockNumber
        
        # Sende ACK-Paket an den Client	
        $UdpClient.Send($bytes, $bytes.Length, $Endpoint)
        Write-Host "ACK-Paket für Block 0 gesendet an $($Endpoint.Address):$($Endpoint.Port)"
        
        # Dateiempfang aktivieren
        $fileReceivingMode = $true
      }
      $TFTP_OPCODE_DATA {
        # Wenn $fileReceivingMode nicht gesetzt ist, dann ist es ein Fehler
        if (-not $fileReceivingMode) {
          Write-Host "DATA-Paket empfangen, aber kein WRQ aktiv. Ignoriere."
          
          # Zutaten für ERROR-Paket
          $opcode = $TFTP_OPCODE_ERROR # ERROR Opcode 
          $errorCode = 4 # Fehlercode 4: Illegal TFTP Operation
          
          # Byte Array von 2 Bytes aus Opcode mit Big Endian vorbereiten	
          $arrayOpcode = [System.BitConverter]::GetBytes($opcode)
          [array]::Reverse($arrayOpcode)

          # Byte Array von 2 Bytes aus Fehlercode mit Big Endian vorbereiten
          $arrayErrorCode = [System.BitConverter]::GetBytes($errorCode)
          [array]::Reverse($arrayErrorCode)

          # Fehlernachricht als Byte Array
          $errorMessage = "Keine WRQ-Anforderung aktiv." # ASCII
          $arrayErrorMessage = [System.Text.Encoding]::ASCII.GetBytes($errorMessage)
          
          # Byte Array für ERROR-Paket erstellen
          $array = $arrayOpcode + $arrayErrorCode + $arrayErrorMessage + [byte]0
          
          # Fehlerantwort senden
          $UdpClient.Send($array, $array.Length, $Endpoint)
          Write-Host "Fehlerantwort gesendet an $($Endpoint.Address):$($Endpoint.Port)"

          continue
        }

        # DATA empfangen
        Write-Host "DATA-Paket empfangen von $($Endpoint.Address):$($Endpoint.Port)"
        
        # Blocknummer auslesen und in Integer umwandeln
        $blockNumberBytes = $ReceiveBytes[2..3]
        [array]::Reverse($blockNumberBytes) # kommt als Big Endian daher reversieren
        $currentBlockNumber = [BitConverter]::ToUInt16($blockNumberBytes, 0)
        
        if ($currentBlockNumber -eq $lastBlockNumber) {
          Write-Host "Doppelter Block empfangen. Ignoriere."
          continue
        }
        else {
          $lastBlockNumber = $currentBlockNumber
        }

        $data = $ReceiveBytes[4..($ReceiveBytes.Length - 1)]
        
        $numBlocks = [math]::Ceiling($fileSize / $blockSize)
        

        # Datei öffnen und Daten anhängen
        $fileStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Append)
        $fileStream.Write($data, 0, $data.Length)
        $fileStream.Close()

        Write-Host "Block $currentBlockNumber von $numBlocks empfangen."

        # ACK-Paket erstellen und senden
        $opcode = $TFTP_OPCODE_ACK # ACK Opcode

        $arrayOpcode = [System.BitConverter]::GetBytes($opcode)
        [array]::Reverse($arrayOpcode)
        
        $arrayBlockNumber = [System.BitConverter]::GetBytes($currentBlockNumber)
        [array]::Reverse($arrayBlockNumber)

        $bytes = $arrayOpcode + $arrayBlockNumber
        
        $UdpClient.Send($bytes, $bytes.Length, $Endpoint)
        Write-Host "ACK-Paket für Block $currentBlockNumber gesendet an $($Endpoint.Address):$($Endpoint.Port)"
        
        # Prüfe, ob letzter Block empfangen wurde
        if ($currentBlockNumber -eq $numBlocks) {
          
          Write-Host "Letzter Block empfangen. Übertragung abgeschlossen."  
          Write-Host "Datei '$fileName' mit $fileSize Bytes gespeichert."
          $fileReceivingMode = $false
          break
        }        
      }
      $TFTP_OPCODE_ACK {
        # ACK
        Write-Host "ACK-Paket empfangen von $($Endpoint.Address):$($Endpoint.Port)"
      }
      $TFTP_OPCODE_ERROR {
        # ERROR
        Write-Host "ERROR-Paket empfangen von $($Endpoint.Address):$($Endpoint.Port)"
      }
      default {
        Write-Host "Unbekannter Opcode: $Opcode"
        continue
      }
    }
  }
}
catch {
  Write-Host "Fehler: ($_.Exception.Message)"
}
finally {  
  # Ressourcen freigeben
  $UdpClient.Close()
  Write-Host "UDP-Client geschlossen."
}
       

# Sicherstellen, dass alle Blöcke korrekt verarbeitet werden
Write-Host "TFTP-Server beendet."

# SIG # Begin signature block
# MIIdIQYJKoZIhvcNAQcCoIIdEjCCHQ4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUlBu47S+iZEmm/nMFk9VJjYRM
# VY+gghcgMIIEGTCCAwGgAwIBAgIQNVooowG0K5pH3/ejj6JFbTANBgkqhkiG9w0B
# AQsFADCBkDEcMBoGA1UECgwTUHJpdmF0ZSBEZXZlbG9wbWVudDELMAkGA1UEBwwC
# REExCzAJBgNVBAgMAkhFMQswCQYDVQQGEwJERTEkMCIGCSqGSIb3DQEJARYVbm8u
# bWFpbEBsb2NhbGhvc3Qub3JnMSMwIQYDVQQDDBpEYW5ueU1hbnVhbCBIZWxwZXIg
# U2NyaXB0czAeFw0yNTA1MTQxNDM0MTNaFw0yNjA1MTQxNDU0MTNaMIGQMRwwGgYD
# VQQKDBNQcml2YXRlIERldmVsb3BtZW50MQswCQYDVQQHDAJEQTELMAkGA1UECAwC
# SEUxCzAJBgNVBAYTAkRFMSQwIgYJKoZIhvcNAQkBFhVuby5tYWlsQGxvY2FsaG9z
# dC5vcmcxIzAhBgNVBAMMGkRhbm55TWFudWFsIEhlbHBlciBTY3JpcHRzMIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4dSRFE7nzkNdDE+PwcEAD/OnD8Zl
# 4xqRhTZ9BkUjRFwWzIoM0U8PZdK8kLVgL9/C784CiT8gQVNxnOtV0TdfRsadCfaZ
# p5L5n1+PtsyHbIrf8ypRHQMXzsT1jyRbkPiQuyKFwWz7Ik1Hg6lSrpqalPsqQM6M
# O9UOEfsoplga5Jwyem7eImAoNT1Lzi2+ZQdnts2VZ1y1q7jX7IsuwUMuSLfktctX
# WTdeb5w5XZSXyDXvZmPHGxCQuY3Qe2fzOifQvlJl7bOcFMftZQCOPMQIf58MpbyH
# Y1Mk79wliX0hiRyPdW2Pl3RSM56+TMgUjNAgTroVmXwJiwNnz3lRoubjWQIDAQAB
# o20wazAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwJQYDVR0R
# BB4wHIIaRGFubnlNYW51YWwgSGVscGVyIFNjcmlwdHMwHQYDVR0OBBYEFMqTJoiR
# Csno3wKSNAvFtFuITT73MA0GCSqGSIb3DQEBCwUAA4IBAQAjsdYoq5WMuYEnKJmT
# IJJYAnXlTWuoll6KhK16L4KkmXxGP1hC7uMZK6h6vwv2xbD4JFUlQasxP1ZJ2Nr1
# +X0VOrYscfSkQm31EMeeN0hKh0T0fTDHAJ/9xjECEDc1gsrWxi4bJP1nEN8bCeYd
# i/CeVMRkfByEqtApUy3GLwp3PXC+pkvpK5qs2pnvUz7UfK7UWKxBd6XEzoUMFUqf
# HHd7k8oyB8XJqFve9jqKFq8PNZ9/uKecv4ZGU255AlMSFLsdnMljBmm3gOe423Tk
# HrrNj2cgJzqscHzfG5Eqf29dNUU6+DyFPP/5OjmIQTc8bo7yZZUazxbATFi7jU1c
# hj7cMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwF
# ADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQL
# ExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElE
# IFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKn
# JS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/W
# BTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHi
# LQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhm
# V1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHE
# tWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6
# MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mX
# aXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZ
# xd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfh
# vbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvl
# EFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn1
# 5GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNV
# HQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4Ix
# LVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggr
# BgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdo
# dHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290
# Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRVHSAA
# MA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzs
# hV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre
# +i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8v
# C6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38
# dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5xaiNr
# Iv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGrjCCBJagAwIB
# AgIQBzY3tyRUfNhHrP0oZipeWzANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJV
# UzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQu
# Y29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjIwMzIz
# MDAwMDAwWhcNMzcwMzIyMjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMO
# RGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNB
# NDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAxoY1BkmzwT1ySVFVxyUDxPKRN6mXUaHW0oPRnkyibaCwzIP5
# WvYRoUQVQl+kiPNo+n3znIkLf50fng8zH1ATCyZzlm34V6gCff1DtITaEfFzsbPu
# K4CEiiIY3+vaPcQXf6sZKz5C3GeO6lE98NZW1OcoLevTsbV15x8GZY2UKdPZ7Gnf
# 2ZCHRgB720RBidx8ald68Dd5n12sy+iEZLRS8nZH92GDGd1ftFQLIWhuNyG7QKxf
# st5Kfc71ORJn7w6lY2zkpsUdzTYNXNXmG6jBZHRAp8ByxbpOH7G1WE15/tePc5Os
# LDnipUjW8LAxE6lXKZYnLvWHpo9OdhVVJnCYJn+gGkcgQ+NDY4B7dW4nJZCYOjgR
# s/b2nuY7W+yB3iIU2YIqx5K/oN7jPqJz+ucfWmyU8lKVEStYdEAoq3NDzt9KoRxr
# OMUp88qqlnNCaJ+2RrOdOqPVA+C/8KI8ykLcGEh/FDTP0kyr75s9/g64ZCr6dSgk
# Qe1CvwWcZklSUPRR8zZJTYsg0ixXNXkrqPNFYLwjjVj33GHek/45wPmyMKVM1+mY
# Slg+0wOI/rOP015LdhJRk8mMDDtbiiKowSYI+RQQEgN9XyO7ZONj4KbhPvbCdLI/
# Hgl27KtdRnXiYKNYCQEoAA6EVO7O6V3IXjASvUaetdN2udIOa5kM0jO0zbECAwEA
# AaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFLoW2W1NhS9z
# KXaaL3WMaiCPnshvMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4G
# A1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRr
# MGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEF
# BQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3Rl
# ZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZn
# gQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQB9WY7Ak7ZvmKlE
# IgF+ZtbYIULhsBguEE0TzzBTzr8Y+8dQXeJLKftwig2qKWn8acHPHQfpPmDI2Avl
# XFvXbYf6hCAlNDFnzbYSlm/EUExiHQwIgqgWvalWzxVzjQEiJc6VaT9Hd/tydBTX
# /6tPiix6q4XNQ1/tYLaqT5Fmniye4Iqs5f2MvGQmh2ySvZ180HAKfO+ovHVPulr3
# qRCyXen/KFSJ8NWKcXZl2szwcqMj+sAngkSumScbqyQeJsG33irr9p6xeZmBo1aG
# qwpFyd/EjaDnmPv7pp1yr8THwcFqcdnGE4AJxLafzYeHJLtPo0m5d2aR8XKc6UsC
# Uqc3fpNTrDsdCEkPlM05et3/JWOZJyw9P2un8WbDQc1PtkCbISFA0LcTJM3cHXg6
# 5J6t5TRxktcma+Q4c6umAU+9Pzt4rUyt+8SVe+0KXzM5h0F4ejjpnOHdI/0dKNPH
# +ejxmF/7K9h+8kaddSweJywm228Vex4Ziza4k9Tm8heZWcpw8De/mADfIBZPJ/tg
# ZxahZrrdVcA6KYawmKAr7ZVBtzrVFZgxtGIJDwq9gdkT/r+k0fNX2bwE+oLeMt8E
# ifAAzV3C+dAjfwAL5HYCJtnwZXZCpimHCUcr5n8apIUP/JiW9lVUKx+A+sDyDivl
# 1vupL0QVSucTDh3bNzgaoSv27dZ8/DCCBrwwggSkoAMCAQICEAuuZrxaun+Vh8b5
# 6QTjMwQwDQYJKoZIhvcNAQELBQAwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRp
# Z2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQw
# OTYgU0hBMjU2IFRpbWVTdGFtcGluZyBDQTAeFw0yNDA5MjYwMDAwMDBaFw0zNTEx
# MjUyMzU5NTlaMEIxCzAJBgNVBAYTAlVTMREwDwYDVQQKEwhEaWdpQ2VydDEgMB4G
# A1UEAxMXRGlnaUNlcnQgVGltZXN0YW1wIDIwMjQwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQC+anOf9pUhq5Ywultt5lmjtej9kR8YxIg7apnjpcH9CjAg
# QxK+CMR0Rne/i+utMeV5bUlYYSuuM4vQngvQepVHVzNLO9RDnEXvPghCaft0djvK
# KO+hDu6ObS7rJcXa/UKvNminKQPTv/1+kBPgHGlP28mgmoCw/xi6FG9+Un1h4eN6
# zh926SxMe6We2r1Z6VFZj75MU/HNmtsgtFjKfITLutLWUdAoWle+jYZ49+wxGE1/
# UXjWfISDmHuI5e/6+NfQrxGFSKx+rDdNMsePW6FLrphfYtk/FLihp/feun0eV+pI
# F496OVh4R1TvjQYpAztJpVIfdNsEvxHofBf1BWkadc+Up0Th8EifkEEWdX4rA/FE
# 1Q0rqViTbLVZIqi6viEk3RIySho1XyHLIAOJfXG5PEppc3XYeBH7xa6VTZ3rOHNe
# iYnY+V4j1XbJ+Z9dI8ZhqcaDHOoj5KGg4YuiYx3eYm33aebsyF6eD9MF5IDbPgjv
# wmnAalNEeJPvIeoGJXaeBQjIK13SlnzODdLtuThALhGtyconcVuPI8AaiCaiJnfd
# zUcb3dWnqUnjXkRFwLtsVAxFvGqsxUA2Jq/WTjbnNjIUzIs3ITVC6VBKAOlb2u29
# Vwgfta8b2ypi6n2PzP0nVepsFk8nlcuWfyZLzBaZ0MucEdeBiXL+nUOGhCjl+QID
# AQABo4IBizCCAYcwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMB8GA1UdIwQYMBaAFLoW2W1NhS9zKXaaL3WMaiCPnshvMB0GA1UdDgQWBBSf
# VywDdw4oFZBmpWNe7k+SH3agWzBaBgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2VGlt
# ZVN0YW1waW5nQ0EuY3JsMIGQBggrBgEFBQcBAQSBgzCBgDAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFgGCCsGAQUFBzAChkxodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2
# VGltZVN0YW1waW5nQ0EuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQA9rR4fdplb4ziE
# EkfZQ5H2EdubTggd0ShPz9Pce4FLJl6reNKLkZd5Y/vEIqFWKt4oKcKz7wZmXa5V
# gW9B76k9NJxUl4JlKwyjUkKhk3aYx7D8vi2mpU1tKlY71AYXB8wTLrQeh83pXnWw
# wsxc1Mt+FWqz57yFq6laICtKjPICYYf/qgxACHTvypGHrC8k1TqCeHk6u4I/VBQC
# 9VK7iSpU5wlWjNlHlFFv/M93748YTeoXU/fFa9hWJQkuzG2+B7+bMDvmgF8VlJt1
# qQcl7YFUMYgZU1WM6nyw23vT6QSgwX5Pq2m0xQ2V6FJHu8z4LXe/371k5QrN9FQB
# hLLISZi2yemW0P8ZZfx4zvSWzVXpAb9k4Hpvpi6bUe8iK6WonUSV6yPlMwerwJZP
# /Gtbu3CKldMnn+LmmRTkTXpFIEB06nXZrDwhCGED+8RsWQSIXZpuG4WLFQOhtloD
# RWGoCwwc6ZpPddOFkM2LlTbMcqFSzm4cd0boGhBq7vkqI1uHRz6Fq1IX7TaRQuR+
# 0BGOzISkcqwXu7nMpFu3mgrlgbAW+BzikRVQ3K2YHcGkiKjA4gi4OA/kz1YCsdhI
# BHXqBzR0/Zd2QwQ/l4Gxftt/8wY3grcc/nS//TVkej9nmUYu83BDtccHHXKibMs/
# yXHhDXNkoPIdynhVAku7aRZOwqw6pDGCBWswggVnAgEBMIGlMIGQMRwwGgYDVQQK
# DBNQcml2YXRlIERldmVsb3BtZW50MQswCQYDVQQHDAJEQTELMAkGA1UECAwCSEUx
# CzAJBgNVBAYTAkRFMSQwIgYJKoZIhvcNAQkBFhVuby5tYWlsQGxvY2FsaG9zdC5v
# cmcxIzAhBgNVBAMMGkRhbm55TWFudWFsIEhlbHBlciBTY3JpcHRzAhA1WiijAbQr
# mkff96OPokVtMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAA
# MBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgor
# BgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBROy4r8HvyXzJtt0OdNS5ddmyYIDDAN
# BgkqhkiG9w0BAQEFAASCAQCLOwsCzmqTLK+Luo4p24VMVShshNWPtuRX3M0sP/4c
# yv5/zVShSJfSTOYB4AEhJbxRsAnM0HVJHNwkp6sZBuV5epV+sZXBDCkcUhkwz6rz
# +Wa6rO9rdNImvGt+gJTAnkWEcuMpUlLpU49PgGb3Ef0Qk9/NGY12d4jTgyUmqXIt
# a9QAoMTsFO3ZUK3i+QWMAY4Oq7fGUh1evNHitGshEQCcsZcKNUtxqy5k+pWjxQJI
# 9XGIpagksI2NpwLg2LLaVzp81nKRLCtLAieXqKiHYFDIfa4J5q6VZmvX98NPuPek
# zDWyNSxQZ4EgunulDKqtbFqegg/dyTmcdICQfiA4baqqoYIDIDCCAxwGCSqGSIb3
# DQEJBjGCAw0wggMJAgEBMHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYg
# U0hBMjU2IFRpbWVTdGFtcGluZyBDQQIQC65mvFq6f5WHxvnpBOMzBDANBglghkgB
# ZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkF
# MQ8XDTI1MDUxNDE1MjExMVowLwYJKoZIhvcNAQkEMSIEIIckyNX8N39buMoxgLwr
# v9Yys9GwaGlvQ9ld1rhDx0i0MA0GCSqGSIb3DQEBAQUABIICACvw/gK6Fx34SBde
# qk4l19iyIWWNN59TpjZ55zs/A41yXNu3QRi0BPHKD06NVO6c2/c4IPMQAZtbU+AU
# 5exPd7D4kI89EIErdUIVWS2kzLYeTQvD+BkME2q2Eo/kMDUFt3tLXrP0wfqQ43Pk
# cK4V+e1Pmd9EWcRdWr/LjsuqwWDgp7Hy9PAIII2Gi+N8lsKmuFIipt38Fc/X7v2X
# M7Q7FsziaChxSvpuaT9zuuNeI+h9YB8mbZZoYLG6c5jhpxXPRlYmjQUGU1FzmKsa
# XoQ6yWNtNHCvjEYoQs84yp/5dX8kJWXYQlBal4SrgUyIY8yWRFXgZskUjSPtRdkU
# 9dlHlHsEsJLgkR0gAw77QYqJn2crZ2R0WKYbbXfT5q24PyMiVjIxPc9E2ZzeCh4+
# TkqiJBaJ8dEzGwzXCH5y+hrJCE2PosLduNF8aW43C+TlHXr1ebLzPWXro+q0YYrn
# 6Sn8ikucX6p7LkQJFbxQGUiZ7NL+pbILAELu9pcW/ACA8XVIzM0O4tGfaLhewfkc
# MjnQvvrAwX//QxkWtWs2e34QyqIU6gnkWhZLAibdtgpYC+04xU1FvKmo0StJqu9W
# JSiJamQUtcag8YfSoxQUAW/Z/DkgeQhE4dGFvr9CnDHI5SQkA7Nll/rnXhhMpuH6
# 2A82hQ17yijH8z1jIFyMDQCnWyOD
# SIG # End signature block
