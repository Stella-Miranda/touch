/// The three Đông Hồ paintings this app is deployed with, each paired with
/// the introduction the client wrote for it.
///
/// The introductions are *not* generated. They are the client's own script,
/// spoken verbatim, because they carry cultural detail (the ngũ đức of the
/// rooster, the “cá chép hóa rồng” legend, the lotus mat under the boy) that
/// a model looking at a photograph would paraphrase, thin out or get wrong.
/// The model's only job here is recognition: deciding *which* of the three is
/// in front of the camera. Everything the visitor hears before the pointing
/// session begins is fixed text.
class DongHoPainting {
  const DongHoPainting({
    required this.code,
    required this.title,
    required this.recognitionHint,
    required this.introduction,
  });

  /// The exact token the recognition model is asked to answer with. Kept
  /// ASCII and underscore-separated so a reply can be matched with a plain
  /// substring test, with no accent or casing normalisation needed.
  final String code;

  final String title;

  /// What the painting looks like, used only to build the recognition prompt.
  /// This describes the *picture*, not its meaning — the model is being asked
  /// to tell three images apart, so only visible features help it.
  final String recognitionHint;

  /// Spoken in full, before the pointing session starts.
  final String introduction;

}

/// Recognised in this order; the codes share no common substring, so the
/// first code present in the model's reply is the answer.
const List<DongHoPainting> kDongHoPaintings = [
  DongHoPainting(
    code: 'LY_NGU',
    title: 'Lý ngư vọng nguyệt',
    recognitionHint:
        'một con cá chép lớn đang uốn mình trong nước, ngẩng đầu trông lên '
        'bóng mặt trăng tròn; xung quanh có lá sen, rong hoặc bèo',
    introduction:
        'Bây giờ chúng ta sẽ cùng khám phá bức tranh Lý ngư vọng nguyệt, hay '
        'còn gọi là Cá chép trông trăng.\n\n'
        'Tranh cá chép trông trăng thường bao gồm hình ảnh cá chép và mặt '
        'trăng, đều là những hình ảnh đẹp, giàu ý nghĩa biểu tượng.\n\n'
        'Cá chép gắn liền với hình ảnh cá vượt vũ môn, biểu tượng cho sự '
        'thăng tiến về tiền tài, công danh và sự nghiệp.\n\n'
        'Cá chép nhắc người ta nhớ đến truyền thuyết nổi tiếng Cá chép hóa '
        'rồng. Vì thế, tranh cá chép ngắm trăng được dùng như là tấm gương '
        'của ý chí, nỗ lực, vượt qua giới hạn bản thân để đến được bến bờ '
        'thành công.\n\n'
        'Cá chép trông trăng còn là biểu tượng đỉnh cao của triết lý phương '
        'Đông. Bức tranh tượng trưng cho khát vọng vươn tới sự hoàn mỹ, trí '
        'tuệ minh triết và sự viên mãn. Bóng trăng tròn dưới đáy nước là ảo '
        'ảnh, nhắc nhở con người hãy phân định rõ thực và hư, tránh theo đuổi '
        'những giá trị phù phiếm mà hướng tới chân lý đích thực.\n\n'
        'Bây giờ, chúng ta sẽ không chỉ nghe kể về bức tranh. Hãy dùng đôi '
        'bàn tay để tự mình khám phá nhé!',
  ),
  DongHoPainting(
    code: 'GA_DA_XUONG',
    title: 'Gà dạ xướng',
    recognitionHint:
        'một con gà trống đứng một mình, mào đỏ lớn, bộ lông đuôi dài nhiều '
        'màu, đang vươn cổ gáy; thường có vài chữ Hán bên cạnh',
    introduction:
        'Bây giờ chúng ta sẽ cùng khám phá bức tranh Đông Hồ có tên là Gà dạ '
        'xướng.\n\n'
        'Trong quan niệm của người Việt, gà trống là biểu tượng của ngũ đức: '
        'Văn, Vũ, Dũng, Nhân và Tín. Đó là những đức tính tốt đẹp, những phẩm '
        'chất cần có ở một người dũng sĩ.\n\n'
        'Gà trống thường cất tiếng gáy vào buổi sáng. Tiếng gáy báo hiệu một '
        'ngày mới bắt đầu, như gọi mặt trời thức dậy và mang ánh sáng đến cho '
        'mọi người.\n\n'
        'Trong bức tranh này, chú gà trống có bộ lông và chiếc mào rất đẹp. '
        'Dù mưa hay gió, chú vẫn cất tiếng gáy đều đặn mỗi buổi sáng.\n\n'
        'Tranh Gà dạ xướng đặc biệt nhắc nhở con người về chữ Tín, một đức '
        'tính rất quan trọng trong gia đình, trong tình bạn và trong cuộc '
        'sống.\n\n'
        'Tín nghĩa là đã hứa thì cố gắng thực hiện, đã nói thì phải giữ lời.\n\n'
        'Tiếng gà gáy còn được xem như tiếng gọi mặt trời, xua tan bóng tối '
        'và mang đến một ngày mới tràn đầy may mắn, niềm vui và hy vọng.\n\n'
        'Bây giờ, chúng ta sẽ không chỉ nghe kể về bức tranh. Chúng ta sẽ '
        'dùng đôi bàn tay để tự mình khám phá nó nhé!',
  ),
  DongHoPainting(
    code: 'CHAN_TRAU',
    title: 'Chăn trâu thổi sáo',
    recognitionHint:
        'một cậu bé mục đồng ngồi trên lưng con trâu, đang thổi sáo, đầu che '
        'một chiếc lá sen lớn; bên dưới cậu bé là hoa sen và lá sen',
    introduction:
        'Bây giờ chúng ta sẽ cùng khám phá một bức tranh Đông Hồ có tên là '
        'Chăn trâu thổi sáo.\n\n'
        'Đây là một trong những bức tranh dân gian quen thuộc, thể hiện cuộc '
        'sống và ước vọng của người Việt xưa, đặc biệt là những người nông '
        'dân gắn bó với ruộng đồng.\n\n'
        'Việt Nam là một đất nước có truyền thống trồng lúa nước. Vì vậy, '
        'hình ảnh cậu bé mục đồng cưỡi trâu giữa đồng cỏ, dưới bầu trời rộng '
        'lớn gợi lên ước mong về thiên nhiên thuận hòa, mùa màng tốt tươi và '
        'cuộc sống bình yên, no đủ.\n\n'
        'Trong tranh, cậu bé có khuôn mặt hồn nhiên, ngồi ung dung trên lưng '
        'trâu và say sưa thổi sáo.\n\n'
        'Trên đầu cậu là một chiếc lá sen lớn, vừa che nắng vừa tạo nên vẻ '
        'đẹp rất tự nhiên.\n\n'
        'Đặc biệt, cậu bé không ngồi trực tiếp lên lưng trâu. Bên dưới cậu là '
        'một tấm thảm được tạo nên từ hoa sen, lá sen và những cọng sen.\n\n'
        'Tất cả tạo nên một hình ảnh rất yên bình: con người, con trâu và '
        'thiên nhiên cùng hòa vào nhau.\n\n'
        'Bây giờ, chúng ta sẽ không chỉ nghe kể về bức tranh. Hãy dùng đôi '
        'bàn tay để tự mình khám phá nhé!',
  ),
];
