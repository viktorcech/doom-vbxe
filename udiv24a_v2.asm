; udiv24 for Antonia II hardware
;
; m_quot:m_rem = m_prod / m_den
;
antdiv_dd = $fff008
antdiv_ds = antdiv_dd+2
antdiv_qu = antdiv_dd
antdiv_re = antdiv_qu+2
;
	.LONGA OFF
udiv24_antonia2
	lda m_prod+2
	rep #$20
	.LONGA ON
	beq ?fast16

	lda m_prod+1
	sta.l antdiv_dd
	lda m_den
	sta.l antdiv_ds
	lda.l antdiv_qu
	sta ?q_hi

	lda.l antdiv_re
	cmp #256
	bcc ?hw2

	lda m_prod
	and #$00ff
	xba
	sta ?q_lo

	lda.l antdiv_re

	ldx #$08
?lp8	asl ?q_lo
	rol
	bcs ?sub

	cmp m_den
	bcc ?s8

?sub	sbc m_den

	inc ?q_lo

?s8	dex
	bne ?lp8

	sta m_rem

	lda ?q_hi
	and #$00ff
	xba
	ora ?q_lo
	sta m_quot
	sep #$20
	.LONGA OFF
	rts

	.LONGA ON
?hw2	xba
	sep #$20
	.LONGA OFF
	ora m_prod
	rep #$20
	.LONGA ON
	sta.l antdiv_dd
	lda m_den
	sta.l antdiv_ds
	lda.l antdiv_re
	sta m_rem

	lda ?q_hi
	and #$00ff
	xba
	ora.l antdiv_qu
	sta m_quot
	sep #$20
	.LONGA OFF
	rts

	.LONGA ON
?fast16	lda m_prod
	sta.l antdiv_dd
	lda m_den
	sta.l antdiv_ds
	lda.l antdiv_qu
	sta m_quot
	lda.l antdiv_re
	sta m_rem
	sep #$20
	.LONGA OFF
	rts

?q_hi	.word 0
?q_lo	.word 0
