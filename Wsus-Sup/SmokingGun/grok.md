Yes, expired PatchMyPC-issued certificates ("patchmypc" and "wsus" nicknames) from the GPO—likely deployed for a partial Cloud setup on servers—conflict with your Publisher (on-premises) integration in SCCM/WSUS. 

Publisher requires valid WSUS signing certs for third-party update publishing and client trust; expired ones cause sync failures (e.g., connection refused on 8531 due to SSL mismatch), service detachment, and install errors like 0x800b0109/0x800b0101.

Cloud attempts (SaaS, cert-based auth) on servers add orphaned configs/registry entries, exacerbating WSUS corruption without full cleanup.

Intune handles endpoints (no WSUS), but servers remain WSUS-dependent, amplifying the issue environment-wide.

**Fix:** Renew certs via Publisher (self-signed/PKI, 5+ years), redeploy via GPO to Trusted Root/Publishers stores, republish updates, and clean hybrid remnants (e.g., remove Cloud GPO remnants, verify no dual WSUS).

1. https://patchmypc.com/kb/third-party-updates-fail-to-install-with-error-0x800b0101/  
2. https://patchmypc.com/kb/third-party-updates-fail-to-install-with-error-0x800b0109-in-sccm/  
3. https://docs.patchmypc.com/installation-guides/wsus-standalone/certificate-configuration  
4. https://patchmypc.com/remote-wsus-connection-is-not-https-this-prevents-software-update-point-from-getting-the-signing-certificate-for-third-party-updates  
5. https://patchmypc.com/how-to-deploy-the-wsus-signing-certificate-for-third-party-software-updates  
6. https://patchmypc.com/kb/what-wsus-signing-certificate-how/  
7. https://www.systemcenterdudes.com/how-to-configure-patchmypc-cloud-portal/  
8. https://docs.patchmypc.com/patch-my-pc-cloud/intune-apps/feature-comparison-with-publisher  
9. https://www.reddit.com/r/PatchMyPC/comments/1fz4rez/patch_my_pc_cloud_vs_onprem_platforms/  
10. https://patchmypc.com/wsus-certificate-error-access-denied