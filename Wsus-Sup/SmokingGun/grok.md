Yes, expired PatchMyPC-issued certificates ("patchmypc" and "wsus" nicknames) from the GPO—likely deployed for a partial Cloud setup on servers—conflict with your Publisher (on-premises) integration in SCCM/WSUS. 

Publisher requires valid WSUS signing certs for third-party update publishing and client trust; expired ones cause sync failures (e.g., connection refused on 8531 due to SSL mismatch), service detachment, and install errors like 0x800b0109/0x800b0101.

Cloud attempts (SaaS, cert-based auth) on servers add orphaned configs/registry entries, exacerbating WSUS corruption without full cleanup.

Intune handles endpoints (no WSUS), but servers remain WSUS-dependent, amplifying the issue environment-wide.

**Fix:** Renew certs via Publisher (self-signed/PKI, 5+ years), redeploy via GPO to Trusted Root/Publishers stores, republish updates, and clean hybrid remnants (e.g., remove Cloud GPO remnants, verify no dual WSUS).
