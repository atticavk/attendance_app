<?php

namespace Tests\Unit;

use App\Models\RecruitmentCandidate;
use App\Support\SafeOutboundUrl;
use RuntimeException;
use Tests\TestCase;

class SecurityHardeningTest extends TestCase
{
    public function test_candidate_aadhaar_is_encrypted_and_receives_a_stable_blind_index(): void
    {
        $candidate = new RecruitmentCandidate();
        $candidate->aadhaar_number = '1234 5678 9012';

        $rawValue = (string) $candidate->getAttributes()['aadhaar_number'];

        $this->assertNotSame('1234 5678 9012', $rawValue);
        $this->assertStringNotContainsString('123456789012', $rawValue);
        $this->assertSame('1234 5678 9012', $candidate->aadhaar_number);
        $this->assertSame(
            RecruitmentCandidate::aadhaarLookupHash('123456789012'),
            RecruitmentCandidate::aadhaarLookupHash('1234 5678 9012')
        );
    }

    public function test_outbound_urls_require_https_and_an_allowlisted_public_host(): void
    {
        $this->assertSame(
            'https://8.8.8.8/provider',
            SafeOutboundUrl::assertHttps('https://8.8.8.8/provider', ['8.8.8.8'])
        );

        foreach (['http://8.8.8.8/provider', 'https://127.0.0.1/provider', 'https://localhost/provider'] as $url) {
            try {
                SafeOutboundUrl::assertHttps($url, [(string) parse_url($url, PHP_URL_HOST)]);
                $this->fail('Unsafe URL was accepted: '.$url);
            } catch (RuntimeException) {
                $this->addToAssertionCount(1);
            }
        }
    }
}
