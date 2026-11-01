"""Validate a development/ad-hoc profile and generate explicit export settings.
No certificates, device IDs or profile contents are printed to the job log.
"""
import datetime, fnmatch, pathlib, plistlib, re, sys
profile_file, bundle, directory = sys.argv[1:]
root = pathlib.Path(directory)
with open(profile_file, 'rb') as source:
    profile = plistlib.load(source)
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
    raise SystemExit('Bundle ID inválido.')
entitlements = profile.get('Entitlements', {})
team = (profile.get('TeamIdentifier') or [''])[0]
uuid = profile.get('UUID', '')
if not re.fullmatch(r'[A-Za-z0-9]+', team) or not re.fullmatch(r'[A-Fa-f0-9-]{36}', uuid):
    raise SystemExit('El perfil no tiene Team/UUID válidos.')
prefixes = profile.get('ApplicationIdentifierPrefix') or [team]
application_id = entitlements.get('application-identifier', '')
if not any(application_id.startswith(prefix + '.') and fnmatch.fnmatchcase(bundle, application_id[len(prefix)+1:]) for prefix in prefixes):
    raise SystemExit('El perfil no corresponde al Bundle ID seleccionado.')
expiry = profile.get('ExpirationDate')
if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit('El perfil no existe o ha vencido.')
if profile.get('ProvisionsAllDevices') or not profile.get('ProvisionedDevices'):
    raise SystemExit('Para esta IPA personal usa un perfil development/ad-hoc que incluya tu iPhone.')
options = {'method': 'debugging' if entitlements.get('get-task-allow') else 'release-testing',
           'signingStyle': 'manual', 'teamID': team, 'provisioningProfiles': {bundle: uuid},
           'manageAppVersionAndBuildNumber': False}
(root/'uuid.txt').write_text(uuid)
(root/'team.txt').write_text(team)
(root/'ExportOptions.plist').write_bytes(plistlib.dumps(options))
