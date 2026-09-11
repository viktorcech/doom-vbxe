; umul16 for Antonia II hardware
;
; m_prod = m_a * m_b
;
antmul_f0 = $fff00c
antmul_f1 = antmul_f0+2
antmul_re = antmul_f0
;
umul16_antonia2
	rep #$20
	.LONGA ON
	lda m_a
	sta.l antmul_f0
	lda m_b
	sta.l antmul_f1
	lda.l antmul_re
	sta m_prod
	lda.l antmul_re+2
	sta m_prod+2
	sep #$20
	.LONGA OFF
	rts
